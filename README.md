# aserve — "Apache serve"

**Version 1.0.4**

aserve provides an easy way to "point and serve" a folder without having to copy files to /var/www/html, set up Apache vhosts, or modify permissions. 

Technically, aserve is a bash shell script that temporarily bind-mounts a local folder into Apache's document root (/var/www/html), adds minimal ACLs so Apache's www-data user can read/traverse the files, reloads Apache, and cleans everything up when you stop it. 

aserve is not intended for long-term file serving. (You should set up vhosts instead!)

### This repository contains:
- `aserve.sh` — the script to run on your Debian Linux machine
- README.md - this file
- LICENSE - the MIT license

### Prerequisites
- Debian-based system (tested on LMDE 7 but should work on most Debian/Ubuntu derivatives).
- Apache2 installed and configured to serve `/var/www/html`.
- `acl` package recommended (for setfacl): `sudo apt install acl`
- `mount` and `setfacl` require root. `aserve` must be run with `sudo` for normal operation.
- Optional utilities: `realpath` (recommended). The script has fallbacks to Python for path resolution.

## How it works:

The script creates `/var/www/html/<alias>` and does a `mount --bind /path/to/site /var/www/html/<alias>`. Minimal ACLs are added for `www-data` (rx on the site, x on parent directories up to the user's home). Apache is reloaded so the site is available at `http://localhost/<alias>`.

#### What the script does

1. Resolve requested path to absolute path.
2. Validate that the directory exists.
3. Choose an alias (basename or provided name). If that alias already exists in `/var/www/html`, append a timestamp.
4. Grant minimal ACLs to `www-data` so Apache can read and traverse.
5. Create the destination mountpoint and perform `mount --bind`.
6. Reload Apache and print the served URL.
7. If `-o` flag is passed, open URL in default browser. 
8. Wait until the process receives INT/TERM; then unmount, revoke ACLs, reload Apache.

<br>

# Installation (one-time)
1. Download, and make script executable:
   ```bash
   chmod +x /path/to/aserve.sh
   ```
2. Optionally, install to PATH and set permissions so you can run from anywhere:
   ```bash
   sudo cp /path/to/aserve.sh /usr/local/bin/aserve
   sudo chown root:root /usr/local/bin/aserve
   sudo chmod 755 /usr/local/bin/aserve
   ```
3. Verify install (should display version):
   ```bash
   aserve -v
   ```
<br>

# Usage

Serve `/home/ken/Dev/kdo` (using auto-derived alias `kdo`):
  ```bash
  sudo aserve /home/ken/Dev/kdo
  # Now available at http://localhost/kdo
  ```
Serve with an explicit alias:
  ```bash
  sudo aserve /home/ken/Dev/kdo foobar
  # Now available at http://localhost/foobar
  ```
Serve and auto-open site in default browser:
   ```bash
   sudo aserve -o /home/ken/Dev/kdo
   # Opens http://localhost/kdo in the default web browser
   ```

Show help:
  ```bash
  aserve -h
  ```
Show version number:
  ```bash
  aserve -v
  ```  
Clean up any previous mounts (see below for more info)
  ```bash
  sudo aserve --clean
  ```  

#### Usage Notes:

- If `aliasname` is omitted, the script uses the basename of the supplied path (e.g. `/home/ken/Dev/kdo` → `kdo`).

- If the desired alias already exists in `/var/www/html`, the script appends a timestamp to avoid overwriting.

- Press `Ctrl+C` in the terminal running `aserve` to unmount, remove the mountpoint, revoke the ACLs, and reload Apache.

<br>

# Stopping / Cleanup

Press `Ctrl+C` in the terminal where you started `aserve`. The script traps INT/TERM and will:
  - unmount the bind mount,
  - remove the `/var/www/html/<alias>` mountpoint,
  - revoke the ACL entries it added,
  - reload Apache.

### Cleaning previously-created mounts (--clean)

- If `aserve` exited unexpectedly or the machine rebooted and a bind mount remains, use `--clean` to attempt a safe recovery.

- The script writes a lightweight record file after a successful mount at `/run/aserve/<alias>.record` containing the original source path. `--clean` prefers using that record to find and clean the site.
- When cleaning an alias, `aserve` will also attempt to detect any running `aserve` process(es) that reference the same source path or `/var/www/html/<alias>`. If found, the cleaner offers to terminate those process(es) (SIGTERM, then SIGKILL if needed) so the original terminal process doesn't remain running after the mount is removed.
- If the record is missing, `--clean <alias>` will fall back to resolving `/var/www/html/<alias>` with `findmnt` to determine the bind source.
- `sudo aserve --clean <alias>` (or `--clean /path/to/source`) will:
  - prompt for confirmation,
  - revoke the recursive `www-data` ACL on the recorded source (`setfacl -R -x u:www-data $SRC`),
  - unmount `/var/www/html/<alias>` if mounted,
  - remove the mountpoint directory, remove the `/run/aserve/<alias>.record` file (if present), and
  - reload Apache.
- `sudo aserve --clean` with no argument lists records in `/run/aserve/*.record` and lets you pick one interactively.

### Cleanup Examples:
```bash
# Clean a specific alias using its record (preferred)
sudo aserve --clean kdo

# Clean by source path
sudo aserve --clean /home/ken/Dev/kdo

# Interactively choose a record to clean
sudo aserve --clean
```

You can also clean old (unused) mounts manually:
  ```bash
  sudo umount /var/www/html/<alias> || true
  sudo rmdir /var/www/html/<alias> || true
  sudo setfacl -R -x u:www-data /path/to/site || true
  # And reload apache
  sudo systemctl reload apache2
  ```

<br>

# Error handling & troubleshooting

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
- If the script fails to unmount during cleanup, use the clean option (`--clean`). See the "Stopping / Cleanup" section above for more information.

## Security notes
- The script grants `rx` to `www-data` on your site folder and `x` on parent directories up to your home. This allows the Apache user to traverse and read the files. The script attempts to revoke the ACLs on exit.
- Because it uses bind mounts and modifies ACLs, the script requires `sudo`. Use responsibly; only run it on systems you trust.
- If you want passwordless operation for convenience, consider a targeted polkit rule limited to this exact command — but be aware this elevates privileges and has security implications.

## Notes / caveats
- The script assumes Apache serves from `/var/www/html`. If your configuration differs, pick an appropriate destination or adjust the script.
- The script attempts to be careful with ACLs, but ACL support (`setfacl`) must be present. Install the `acl` package if needed.
- The script uses `systemctl reload apache2` to refresh Apache. If your system's service name is different, adjust the script.
- The `-o` flag uses `xdg-open` and invokes user's desktop session so browser reuses the existing profile (avoids prompts to choose a profile). This is best-effort and designed to be transparent to the user; if the session can't be detected, the script falls back to simply printing the URL on screen.

## License

[MIT](LICENSE) 


## Disclaimer

This script is intended as a quick developer convenience to preview sites using a real Apache server without creating persistent vhosts and should only be used on development boxes. **This script is not intended for production use!**
