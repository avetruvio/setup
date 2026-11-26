# setup

Linux box setup — a standardized install script for VMs and machines to get basic essentials, role-specific packages, Tailscale, and dotfiles configured quickly.

## Usage

Interactive (all prompts are collected upfront before any updates or installs run):
```bash
wget https://raw.githubusercontent.com/avetruvio/setup/main/basicsetup.sh && chmod +x basicsetup.sh && sudo ./basicsetup.sh
```
> On a fresh Alpine Linux install, install `bash` first as root: `apk add --no-cache bash`

Unattended / CLI flags (e.g. for `cloud-init` or automation):
```bash
sudo ./basicsetup.sh -u myuser -t 1 --tailscale --tailscale-key tskey-... --no-reboot -y
```
Run `./basicsetup.sh --help` for all flags (`-u/--user` [defaults to the invoking user], `-t/--type`, `--tailscale`, `--no-tailscale`, `--tailscale-key`, `--github-keys`, `--reboot`, `--no-reboot`, `--scp-dest`, `-y/--yes`).

### Ansible Playbook
An equivalent Ansible playbook is also available in [playbook.yml](playbook.yml):
```bash
ansible-playbook -i "host," playbook.yml -e "target_user=myuser install_type=1 install_tailscale=true tailscale_authkey=tskey-... github_keys_user=myghuser do_reboot=false"
```
Each managed host's `host-ini-info` is automatically fetched back to `./host-configs/<host>-host-ini-info` on the computer running the playbook (override with `-e host_info_dest=/path`).

### Supported Package Managers
Automatically detects the distro via `/etc/os-release` and selects the matching package manager:
- `apt` (Debian / Ubuntu)
- `dnf` / `yum` (Fedora / RHEL / CentOS)
- `pacman` (Arch / Manjaro)
- `zypper` (openSUSE)
- `apk` (Alpine — requires `bash` pre-installed; automatically enables the `community` repo in `/etc/apk/repositories`)

### Install Modes
All modes install base essentials (`openssh-server`/`openssh`, `sudo`, `tmux`, `wget`, `git`, `curl`, `vim`, `htop`, and `fastfetch` where available), Ubuntu-only extras (`software-properties-common`), and dotfiles. Enter `0`–`5` at the prompt, or press `?` to view the full package breakdown for each mode before choosing:
- `0` — Update only (no role-specific packages)
- `1` — Headless server (`arp-scan`)
- `2` — VPN headless server (`openvpn`, `arp-scan`)
- `3` — Netbook (`i3`/`i3wm`, `i3lock`, `lightdm`, `lightdm-gtk-greeter`, `cool-retro-term` [non-Alpine; best-effort on RHEL-family], `picom`/`compton`, `xscreensaver`)
- `4` — Desktop (same `i3` desktop stack)
- `5` — VPS (`openvpn`)

### Tailscale
If you opt to install Tailscale, the script prompts for an optional Tailscale auth key at the start and runs `tailscale up --authkey=...` at the end of setup (leave the key blank to authenticate manually later with `sudo tailscale up`).

### Cleanup, Logging & Reboot
After all updates and installations finish, unused/orphaned packages are automatically removed (`apt-get autoremove -y`, `dnf autoremove -y`, `yum autoremove -y`, or `pacman -Rns`). Optionally, you can enter a GitHub username (or pass `--github-keys USER`) to import public SSH keys into `~/.ssh/authorized_keys`. System info (timestamp, hostname, distro, user, CPU, RAM, GPU if present, and global IP addresses) plus a ready-to-use `~/.ssh/config` snippet are appended to `~/host-ini-info` (created if it doesn't exist), with an optional `scp` prompt. Full setup output is logged to `/var/log/basicsetup.log`. Upon completion, the script deletes itself (`rm -f`), and if you opted to reboot, it displays a 7-second countdown (cancelable with `Ctrl+C`) before rebooting.

## To Do
1. Automate central server config sync
