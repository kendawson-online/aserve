#!/usr/bin/env bash

# aserve.sh - Apache Serve:
# Temporary bind-mount a directory into /var/www/html and give minimal ACLs to www-data.
# Usage: sudo aserve /path/to/site [aliasname]
# If aliasname omitted, the script uses the basename of the path (and appends a timestamp if needed).
# -h or --help prints usage and exits (does not require sudo).

set -euo pipefail

print_help() {
  cat <<'EOF'
Typing sudo aserve /path/to/directory will serve a folder via Apache in /var/www/html

Usage:
  sudo aserve /absolute/or/relative/path/to/site [aliasname]
  sudo aserve -h|--help   Show this help and exit

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

# Require root
if [ "$EUID" -ne 0 ]; then
  echo "Operation cannot be completed without root level access. Please use sudo." >&2
  exit 2
fi

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

  # reload apache to ensure no hangups
  systemctl reload apache2 2>/dev/null || true
  echo "Done."
}

trap cleanup EXIT INT TERM

echo "Granting minimal ACLs for www-data..."
grant_acls

echo "Mounting $SRC -> $DST (bind mount)..."
mount --bind "$SRC" "$DST"

echo "Reloading Apache..."
systemctl reload apache2

echo "Now serving $SRC at http://localhost/$NAME"
echo "Press Ctrl+C or exit to stop and clean up."

# Keep the script alive until interrupted so the mount and ACLs persist.
while true; do sleep 86400; done