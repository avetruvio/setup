# setup

Linux box setup — a standardized install script for VMs and machines to get basic essentials, role-specific packages, Tailscale, and dotfiles configured quickly.

## Usage

```bash
wget https://raw.githubusercontent.com/avetruvio/setup/main/basicsetup.sh && chmod +x basicsetup.sh && sudo ./basicsetup.sh
```

### Install Modes
- `0` — Update only (no role-specific packages)
- `1` — Headless server (`easyrsa`, `arp-scan`)
- `2` — VPN headless server (`openvpn`, `easyrsa`, `arp-scan`)
- `3` — Netbook (`i3`, `i3lock`, `lightdm`, `cool-retro-term`, `compton`, `xscreensaver`)
- `4` — Desktop (same `i3` desktop stack)
- `5` — VPS (`openvpn`)

### Tailscale
If you opt to install Tailscale, the script prompts for an optional Tailscale auth key at the start and runs `tailscale up --authkey=...` at the end of setup (leave the key blank to authenticate manually later with `sudo tailscale up`).

## To Do
1. Automate adding VMs to an SSH config
2. Automate central server config sync
