#!/usr/bin/env bash

# aserve.sh - Apache Serve:
# Temporary bind-mount a directory into /var/www/html and give minimal ACLs to www-data.
# Usage: sudo aserve [ -o ] /path/to/site [aliasname]
# If aliasname omitted, the script uses the basename of the path (and appends a timestamp if needed).
# -h or --help prints usage and exits (does not require sudo).
# Use `--clean [alias|path]` to clean up previously created mounts.

set -euo pipefail
VERSION="1.0.4"

print_help() {
  cat <<'EOF'
Typing sudo aserve /path/to/directory will serve a folder via Apache in /var/www/html

Usage:
  sudo aserve [ -o ] /absolute/or/relative/path/to/site [aliasname]
  sudo aserve -h|--help   Show this help and exit
  sudo aserve -v|--version  Show script version and exit
  sudo aserve --clean [alias|path]  Attempt to clean a previous aserve mount

Notes:
  - The script needs root because it uses mount(2) and setfacl.
  - If aliasname is omitted the folder's basename is used.
  - If the chosen alias already exists under /var/www/html a timestamp is appended.
EOF
}

# Show help if requested (do this before checking for root)
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  print_help
  exit 0
fi

# Show version early if requested
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  printf "aserve version %s\n" "$VERSION"
  exit 0
fi

# Handle a cleanup command early (does not require sudo when invoked by root)
if [ "${1:-}" = "--clean" ]; then
  CLEAN_ARG="${2:-}"

  RECORD_DIR="/run/aserve"
  list_records() {
    ls -1 "${RECORD_DIR}"/*.record 2>/dev/null || true
  }

  pick_and_clean() {
    local sel
    echo "Available records in ${RECORD_DIR}:"
    list_records
    echo
    printf "Type the alias (basename of record, without .record) to clean: "
    read -r sel
    sel="${sel##*/}"
    sel="${sel%.record}"
    CLEAN_ARG="$sel"
  }

  if [ -z "$CLEAN_ARG" ]; then
    pick_and_clean
  fi

  # If CLEAN_ARG looks like a path, prefer using it directly as SRC
  if [ -e "$CLEAN_ARG" ]; then
    # treat as path
    SRC_TO_CLEAN="$(realpath -m "$CLEAN_ARG")"
    NAME_TO_CLEAN="$(basename "$SRC_TO_CLEAN")"
  else
    # try record file
    RECORD_DIR="/run/aserve"
    if [ -f "$RECORD_DIR/$CLEAN_ARG.record" ]; then
      SRC_TO_CLEAN="$(cat "$RECORD_DIR/$CLEAN_ARG.record")"
      NAME_TO_CLEAN="$CLEAN_ARG"
    else
      # try to resolve by checking /var/www/html/<alias>
      if [ -d "/var/www/html/$CLEAN_ARG" ]; then
        NAME_TO_CLEAN="$CLEAN_ARG"
        DST_TO_CLEAN="/var/www/html/$NAME_TO_CLEAN"
        SRC_TO_CLEAN="$(findmnt -n -o SOURCE --target "$DST_TO_CLEAN" 2>/dev/null || true)"
      fi
    fi
  fi

  if [ -z "${SRC_TO_CLEAN:-}" ]; then
    echo "Could not determine source for '${CLEAN_ARG}'. Aborting." >&2
    exit 1
  fi

  printf "About to clean alias='%s' src='%s'\n" "${NAME_TO_CLEAN}" "${SRC_TO_CLEAN}"
  printf "Proceed? [y/N]: "
  read -r yn
  case "$yn" in
    [Yy]*) ;;
    *) echo "Aborted."; exit 0 ;;
  esac

  # Revoke ACLs and unmount
  echo "Revoking ACLs on ${SRC_TO_CLEAN}..."
  setfacl -R -x u:www-data "$SRC_TO_CLEAN" || true
  echo "Attempting to unmount /var/www/html/${NAME_TO_CLEAN} if mounted..."
  if mountpoint -q "/var/www/html/${NAME_TO_CLEAN}"; then
    umount "/var/www/html/${NAME_TO_CLEAN}" || echo "Warning: failed to unmount /var/www/html/${NAME_TO_CLEAN}" >&2
  fi
  rmdir "/var/www/html/${NAME_TO_CLEAN}" 2>/dev/null || true
  rm -f "/run/aserve/${NAME_TO_CLEAN}.record" || true
  # Attempt to find any running aserve processes that reference the same source or dst
  FOUND_PIDS=()
  BASE_SRC_TO_CLEAN="$(basename "$SRC_TO_CLEAN")"
  for P in $(ps -e -o pid=); do
    if [ "$P" -eq "$$" ] 2>/dev/null; then
      continue
    fi
    if [ -r "/proc/$P/cmdline" ]; then
      CMDLINE="$(tr '\0' ' ' < /proc/$P/cmdline || true)"
      case "$CMDLINE" in
        *"$SRC_TO_CLEAN"*|*"/var/www/html/$NAME_TO_CLEAN"*|*"$NAME_TO_CLEAN"*|*"$BASE_SRC_TO_CLEAN"*)
          FOUND_PIDS+=("$P") ;;
      esac
    fi
  done

  if [ ${#FOUND_PIDS[@]} -gt 0 ]; then
    printf "Found running process(es) that appear to be serving this site: %s\n" "${FOUND_PIDS[*]}"
    printf "Would you like to terminate these process(es)? [y/N]: "
    read -r KILL_YN
    case "$KILL_YN" in
      [Yy]* )
        echo "Sending SIGTERM to: ${FOUND_PIDS[*]}"
        for P in "${FOUND_PIDS[@]}"; do
          kill -TERM "$P" 2>/dev/null || true
        done
        # give processes a moment to exit gracefully
        sleep 2
        for P in "${FOUND_PIDS[@]}"; do
          if kill -0 "$P" 2>/dev/null; then
            echo "Process $P still running; sending SIGKILL"
            kill -KILL "$P" 2>/dev/null || true
          fi
        done
        ;;
      * ) echo "Left running processes intact." ;;
    esac
  fi

  systemctl reload apache2 2>/dev/null || true
  echo "Clean complete."
  exit 0
fi

# Require root
if [ "$EUID" -ne 0 ]; then
  echo "Operation cannot be completed without root level access. Please use sudo." >&2
  exit 2
fi

# Support a simple -o flag to auto-open the preview in the user's session using xdg-open
OPEN_BROWSER=0
if [ "${1:-}" = "-o" ]; then
  OPEN_BROWSER=1
  shift
fi

# Helper: pick an environment value (DISPLAY, DBUS_SESSION_BUS_ADDRESS, XAUTHORITY)
get_user_env() {
  key="$1"
  if [ -z "${ORIG_USER:-}" ]; then
    return 1
  fi
  # iterate processes owned by the original user, prefer newer ones
  for pid in $(pgrep -u "$ORIG_USER" 2>/dev/null); do
    if [ -r "/proc/$pid/environ" ]; then
      val=$(tr '\0' '\n' < /proc/$pid/environ | grep -m1 "^${key}=" | cut -d= -f2- || true)
      if [ -n "$val" ]; then
        printf "%s" "$val"
        return 0
      fi
    fi
  done
  return 1
}

if [ $# -lt 1 ]; then
  echo "Usage: sudo $0 /absolute/or/relative/path/to/site [aliasname]" >&2
  exit 2
fi

# Resolve the path to an absolute path even if it's relative.
# Prefer realpath -m (tolerant), otherwise fall back to python3 abspath.
if command -v realpath >/dev/null 2>&1; then
  SRC="$(realpath -m "$1")"
else
  # fallback using python3 to get an absolute path without requiring the path to exist
  if command -v python3 >/dev/null 2>&1; then
    SRC="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")"
  else
    # best-effort fallback (may be less robust)
    SRC="$(cd "$(dirname "$1" 2>/dev/null || echo .)" 2>/dev/null && printf "%s/%s" "$(pwd)" "$(basename "$1")")"
  fi
fi

# Check the directory exists before doing anything else
if [ ! -d "$SRC" ]; then
  echo "The directory $SRC does not exist." >&2
  exit 1
fi

# Determine alias name: second arg if present, otherwise basename of SRC
if [ "${2:-}" != "" ]; then
  NAME="$2"
else
  NAME="$(basename "$SRC")"
fi

DST_BASE="/var/www/html"
DST="$DST_BASE/$NAME"

# If DST exists, append timestamp to avoid clobbering
if [ -e "$DST" ]; then
  TS="$(date +%s)"
  NAME="${NAME}-${TS}"
  DST="$DST_BASE/$NAME"
fi

# Determine the original invoking user's home directory (if any)
ORIG_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
USER_HOME="$(getent passwd "$ORIG_USER" | cut -d: -f6 || true)"

mkdir -p "$DST"

grant_acls() {
  # recursive read+execute on the site directory for www-data
  setfacl -R -m u:www-data:rx "$SRC" || true

  # give execute (traverse) permission on every parent directory up to the user's home (or /)
  CUR="$SRC"
  while [ "$CUR" != "/" ] && [ "$CUR" != "$USER_HOME" ]; do
    CUR="$(dirname "$CUR")"
    setfacl -m u:www-data:x "$CUR" || true
  done
  if [ -n "$USER_HOME" ]; then
    setfacl -m u:www-data:x "$USER_HOME" || true
  fi
}

revoke_acls() {
  # remove the recursive ACL for the site dir
  setfacl -R -x u:www-data "$SRC" || true

  # remove traverse ACLs on parents up to user home
  CUR="$SRC"
  while [ "$CUR" != "/" ] && [ "$CUR" != "$USER_HOME" ]; do
    CUR="$(dirname "$CUR")"
    setfacl -x u:www-data "$CUR" || true
  done
  if [ -n "$USER_HOME" ]; then
    setfacl -x u:www-data "$USER_HOME" || true
  fi
}

cleanup() {
  # Print a clean newline so "^C" doesn't run into the message
  printf "\n"
  echo "Cleaning up..."

  # Attempt to unmount and remove mountpoint
  if mountpoint -q "$DST"; then
    umount "$DST" || { echo "Warning: failed to unmount $DST"; }
  fi
  rmdir "$DST" 2>/dev/null || true

  # Revoke ACLs we added
  revoke_acls
  # Remove record file if present
  if [ -f "/run/aserve/$NAME.record" ]; then
    rm -f "/run/aserve/$NAME.record" || true
  fi

  # reload apache to ensure no hangups
  systemctl reload apache2 2>/dev/null || true
  echo "Done."
}

trap cleanup EXIT INT TERM

echo "Granting minimal ACLs for www-data..."
grant_acls

echo "Mounting $SRC -> $DST (bind mount)..."
mount --bind "$SRC" "$DST"

# Write a lightweight record so --clean can find the origin later
RECORD_DIR="/run/aserve"
mkdir -p "$RECORD_DIR"
echo "$SRC" > "$RECORD_DIR/$NAME.record"

echo "Reloading Apache..."
systemctl reload apache2

echo "Now serving $SRC at http://localhost/$NAME"
echo "Press Ctrl+C or exit to stop and clean up."

# Optionally open the URL in the original user's desktop session
if [ "$OPEN_BROWSER" -eq 1 ]; then
  URL="http://localhost/$NAME"
  if command -v xdg-open >/dev/null 2>&1; then
    if [ -n "$ORIG_USER" ]; then
        # Try to infer desktop session env (DISPLAY, DBUS_SESSION_BUS_ADDRESS, XAUTHORITY,
        # XDG_RUNTIME_DIR, WAYLAND_DISPLAY) so the browser is launched inside the user's
        # active session and re-uses existing profile sockets.
        DISPLAY_VAL="$(get_user_env DISPLAY || true)"
        DBUS_VAL="$(get_user_env DBUS_SESSION_BUS_ADDRESS || true)"
        XAUTH_VAL="$(get_user_env XAUTHORITY || true)"
        XDG_VAL="$(get_user_env XDG_RUNTIME_DIR || true)"
        WAYLAND_VAL="$(get_user_env WAYLAND_DISPLAY || true)"

        # If we found any session-related env, try to run xdg-open with those variables set
        # for the original user. Prefer `sudo -u` (cleaner) when available; fall back to
        # `su -c` if not.
        if [ -n "$DISPLAY_VAL" ] || [ -n "$DBUS_VAL" ] || [ -n "$XDG_VAL" ] || [ -n "$WAYLAND_VAL" ]; then
          if command -v sudo >/dev/null 2>&1; then
            sudo -u "$ORIG_USER" \
              DISPLAY="$DISPLAY_VAL" \
              DBUS_SESSION_BUS_ADDRESS="$DBUS_VAL" \
              XAUTHORITY="$XAUTH_VAL" \
              XDG_RUNTIME_DIR="$XDG_VAL" \
              WAYLAND_DISPLAY="$WAYLAND_VAL" \
              nohup xdg-open "$URL" >/dev/null 2>&1 &
          else
            su - "$ORIG_USER" -c "DISPLAY='$DISPLAY_VAL' DBUS_SESSION_BUS_ADDRESS='$DBUS_VAL' XAUTHORITY='$XAUTH_VAL' XDG_RUNTIME_DIR='$XDG_VAL' WAYLAND_DISPLAY='$WAYLAND_VAL' nohup xdg-open '$URL' >/dev/null 2>&1 &" || echo "Failed to launch xdg-open as $ORIG_USER; try opening: $URL"
          fi
        else
          # fallback to simple su-launch which works when session env is not discoverable
          if command -v sudo >/dev/null 2>&1; then
            sudo -u "$ORIG_USER" nohup xdg-open "$URL" >/dev/null 2>&1 &
          else
            su - "$ORIG_USER" -c "nohup xdg-open '$URL' >/dev/null 2>&1 &" || echo "Failed to launch xdg-open as $ORIG_USER; try opening: $URL"
          fi
        fi
    else
      nohup xdg-open "$URL" >/dev/null 2>&1 &
    fi
  else
    echo "Open this URL in a browser: $URL"
  fi
fi

# Keep the script alive until interrupted so the mount and ACLs persist.
while true; do sleep 86400; done