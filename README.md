# aserve — "Apache serve" — a temporary Apache binder shell script

aserve is a small helper (bash shell script) that temporarily bind-mounts a local folder into Apache's document root (/var/www/html), adds minimal ACLs so Apache's www-data user can read/traverse the files, reloads Apache, and cleans everything up when you stop it. It's intended as a quick way to "point and serve" a folder without editing Apache vhosts. It's not intended for long-term file serving. Just a quick-and-dirty way to quickly see a folder in a web server without having to copy things to to /var/www/html or modify permissions.

This repository contains:
- `aserve.sh` — the script you run on your Debian Linux machine
- README.md - this file

Prerequisites
- Debian-based system (tested on LMDE 6 (faye), but should work on Debian/Ubuntu derivatives).
- Apache2 installed and configured to serve `/var/www/html`.
- `acl` package recommended (for setfacl): `sudo apt install acl`
- `mount` and `setfacl` require root. `aserve` must be run with `sudo` for normal operation.
- Optional utilities: `realpath` (recommended). The script has fallbacks to Python for path resolution.

Quick summary of behavior
- Usage: `sudo aserve /path/to/site [aliasname]`
- If `aliasname` is omitted, the script uses the basename of the supplied path (e.g. `/home/ken/Dev/kdo` → `kdo`).
- The script creates `/var/www/html/<alias>` and does a `mount --bind /path/to/site /var/www/html/<alias>`.
- Minimal ACLs are added for `www-data` (rx on the site, x on parent directories up to the user's home).
- Apache is reloaded so the site is immediately available at `http://localhost/<alias>`.
- Press Ctrl+C in the terminal running `aserve` to unmount, remove the mountpoint, revoke the ACLs, and reload Apache.
- If the desired alias already exists in `/var/www/html`, the script appends a timestamp to avoid overwriting.

Installation (one-time)
1. Make the script executable (if needed):
   ```bash
   chmod +x /path/to/aserve.sh
   ```
2. Install into your PATH so you can call it from anywhere (example installs to `/usr/local/bin`):
   ```bash
   sudo cp /path/to/aserve.sh /usr/local/bin/aserve
   sudo chmod 755 /usr/local/bin/aserve
   ```
3. Verify:
   ```bash
   aserve -h
   ```

Usage examples
- Serve `/home/ken/Dev/kdo` using auto-derived alias (`kdo`):
  ```bash
  sudo aserve /home/ken/Dev/kdo
  # Now available at http://localhost/kdo
  ```
- Serve with an explicit alias:
  ```bash
  sudo aserve /home/ken/Dev/kdo foobar
  # Now available at http://localhost/foobar
  ```
- Show help (does not require sudo):
  ```bash
  aserve -h
  ```

Stopping / Cleanup
- Press Ctrl+C in the terminal where you started `aserve`. The script traps INT/TERM and will:
  - unmount the bind mount,
  - remove the `/var/www/html/<alias>` mountpoint,
  - revoke the ACL entries it added,
  - reload Apache.
- If the script was killed or the machine was rebooted and the mount still exists, you can clean manually:
  ```bash
  sudo umount /var/www/html/<alias> || true
  sudo rmdir /var/www/html/<alias> || true
  sudo setfacl -R -x u:www-data /path/to/site || true
  # And reload apache
  sudo systemctl reload apache2
  ```

Error handling & troubleshooting
- "Operation cannot be completed without root level access. Please use sudo."
  - You attempted to run the script without root. Rerun with `sudo`.
- "The directory /resolved/path does not exist."
  - The supplied path is invalid or non-existent. Verify the path and try again.
- 403 Forbidden when loading the site in the browser:
  - Check Apache error log for details:
    ```bash
    sudo tail -n 80 /var/log/apache2/error.log
    ```
  - Ensure `www-data` has traverse permission on every parent directory (the script tries to add these via ACLs). If `setfacl` is not available, install `acl`.
  - Verify the mount exists:
    ```bash
    mount | grep /var/www/html/<alias>
    ```
- If the script fails to unmount during cleanup, run the manual cleanup commands above.

Security notes
- The script grants `rx` to `www-data` on your site folder and `x` on parent directories up to your home. This allows the Apache user to traverse and read the files. The script attempts to revoke the ACLs on exit.
- Because it uses bind mounts and modifies ACLs, the script requires `sudo`. Use responsibly; only run it on systems you trust.
- If you want passwordless operation for convenience, consider a targeted polkit rule limited to this exact command — but be aware this elevates privileges and has security implications.

How it works (short)
1. Resolve the requested path to an absolute path.
2. Validate that the directory exists.
3. Choose an alias (basename or provided name). If that alias already exists in `/var/www/html`, append a timestamp.
4. Grant minimal ACLs to `www-data` so Apache can read and traverse.
5. Create the destination mountpoint and perform `mount --bind`.
6. Reload Apache and print the served URL.
7. Wait until the process receives INT/TERM; then unmount, revoke ACLs, reload Apache.

Notes / caveats
- The script assumes Apache serves from `/var/www/html`. If your configuration differs, pick an appropriate destination or adjust the script.
- The script attempts to be careful with ACLs, but ACL support (`setfacl`) must be present. Install the `acl` package if needed.
- The script uses `systemctl reload apache2` to refresh Apache. If your system's service name is different, adjust the script.

Future ideas
- GUI wrapper:
  - Quick: a Zenity/YAD launcher that uses `pkexec` to run `aserve` and shows the status.
  - Polished: a GTK (PyGObject) app with an AppIndicator tray icon, recent projects list, and an “Open in browser” button.
  - Advanced: a small privileged helper or systemd-activated service that the GUI talks to, avoiding repeated polkit prompts.
- Non-root fallback:
  - If run without sudo, `aserve` could optionally start a lightweight Python/Node static server as a fallback for quick previews (no ACLs/mounts).
- Explicit --stop or --cleanup mode:
  - Add a `--stop <alias>` or `--cleanup <alias>` mode so another terminal (or GUI) can stop a previously started service without relying on the original process.
- New: `--clean` / `-clean` flag (requested)
  - Purpose: recover from situations where `aserve` exited unexpectedly or the cleanup trap didn't run (e.g., machine reboot, SIGKILL).
  - Suggested behavior for a future implementation:
    - `sudo aserve --clean [alias|path]`
      - If given an alias, attempt to unmount `/var/www/html/<alias>`, remove the mountpoint, revoke ACLs applied to the original source path (if the script recorded it), and reload Apache.
      - If given a path, resolve it and revoke ACLs and unmount any matching bind-mounts.
      - If no argument provided, scan `/var/www/html` for mountpoints that are bind mounts into user home directories (or mounts that match patterns the script creates) and present a list for confirmation before cleaning.
    - Example:
      ```bash
      # Clean a specific alias
      sudo aserve --clean kdo

      # Clean by path
      sudo aserve --clean /home/ken/Dev/kdo

      # Scan and interactively clean all dangling aserve-style mounts
      sudo aserve --clean
      ```
    - Implementation notes:
      - The script could optionally keep a small state file (e.g., `/var/run/aserve-active.json` or `/var/lib/aserve/active.json`) with records of active mounts and source paths so the clean action can precisely revoke ACLs and unmount known entries.
      - Without a state file, the clean mode should be conservative: list candidate mountpoints and ask for confirmation before unmounting or changing ACLs.
      - Always prefer a safety prompt/confirmation for destructive actions.
- Additional niceties:
  - Auto-open browser flag.
  - A verbosity/log option to keep a record of changes for later debugging.
  - A small systemd user unit template for persistent serving (if desired).

License
- MIT 

Enjoy — this is intended as a quick developer convenience to preview sites using a real Apache server without creating persistent vhosts and should only be used on development boxes. Not intended for production use. Ever.
