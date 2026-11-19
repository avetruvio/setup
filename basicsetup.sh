#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (e.g., sudo $0)"
    exit 1
fi

DEFAULT_USER="${SUDO_USER:-root}"
read -r -p "Enter username for dotfiles config [${DEFAULT_USER}]: " target_user
target_user="${target_user:-$DEFAULT_USER}"

if ! id "$target_user" &>/dev/null; then
    echo "Error: user '$target_user' does not exist."
    exit 1
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6)"

echo ""
echo "Select install type (0-5):"
echo "  0 - Update only (no role-specific packages)"
echo "  1 - Headless server"
echo "  2 - VPN headless server"
echo "  3 - Netbook (i3 desktop)"
echo "  4 - Desktop (i3 desktop)"
echo "  5 - VPS (OpenVPN)"
read -r -n 1 -p "Choice [0-5]: " install_type
echo ""

read -r -n 1 -p "Install Tailscale? (y/n): " install_tailscale
echo ""

tailscale_authkey=""
if [[ "$install_tailscale" =~ ^[Yy]$ ]]; then
    read -r -s -p "Enter Tailscale auth key (leave blank to skip): " tailscale_authkey
    echo ""
fi

read -r -n 1 -p "Reboot upon completion? (y/n): " do_reboot
echo ""

echo "Beginning setup, please stand by..."
apt-get update -y
apt-get upgrade -y
apt-get install -y openssh-server tmux wget git curl software-properties-common

install_i3_desktop() {
    add-apt-repository -y ppa:vantuz/cool-retro-term
    apt-get update -y
    apt-get install -y i3 i3lock lightdm cool-retro-term compton \
        xscreensaver xscreensaver-data xscreensaver-data-extra
}

case "$install_type" in
    0)
        echo "Update-only mode selected; skipping role-specific packages."
        ;;
    1)
        apt-get install -y easyrsa arp-scan
        ;;
    2)
        apt-get install -y openvpn easyrsa arp-scan
        ;;
    3|4)
        install_i3_desktop
        ;;
    5)
        apt-get install -y openvpn
        ;;
    *)
        echo "Invalid install type '$install_type'; skipping role-specific packages."
        ;;
esac

if [[ "$install_tailscale" =~ ^[Yy]$ ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    distro_id="${ID:-ubuntu}"
    codename="${VERSION_CODENAME:-focal}"
    curl -fsSL "https://pkgs.tailscale.com/stable/${distro_id}/${codename}.noarmor.gpg" \
        | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/${distro_id}/${codename}.tailscale-keyring.list" \
        | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt-get update -y
    apt-get install -y tailscale
else
    echo "Tailscale install bypassed, continuing..."
fi

install_dotfiles() {
    local user="$1"
    local home_dir="$2"
    local dotfiles_dir="${home_dir}/.dotfiles"

    echo "Installing dotfiles for ${user} in ${home_dir}..."

    if [ -d "$dotfiles_dir" ]; then
        echo "Dotfiles directory ${dotfiles_dir} already exists; skipping clone."
        return 0
    fi

    sudo -u "$user" /usr/bin/git clone --bare https://github.com/avetruvio/config.git "$dotfiles_dir"

    local git_cmd=(sudo -u "$user" /usr/bin/git --git-dir="$dotfiles_dir" --work-tree="$home_dir")

    if ! "${git_cmd[@]}" checkout 2>/dev/null; then
        echo "Removing conflicting pre-existing dotfiles..."
        "${git_cmd[@]}" checkout 2>&1 \
            | grep -E "^\s+\." \
            | awk '{print $1}' \
            | xargs -r -I{} rm -f "${home_dir}/{}"
        "${git_cmd[@]}" checkout
    fi

    "${git_cmd[@]}" config --local status.showUntrackedFiles no
    echo "Dotfiles install successful."
}

install_dotfiles "$target_user" "$target_home"

apt-get autoremove -y

info_file="${target_home}/host-ini-info"
{
    echo "$HOSTNAME"
    ip a | grep "scope global" || true
    echo "Hostname: $HOSTNAME"
    echo "User: $target_user"
} >> "$info_file"
chown "${target_user}:${target_user}" "$info_file"

echo "Host info stored in ${info_file}."
read -r -p "SCP host-ini-info to central server? Enter destination (e.g. user@host:/path/) or leave blank to skip: " scp_dest
if [ -n "$scp_dest" ]; then
    scp "$info_file" "$scp_dest" || echo "Warning: scp to ${scp_dest} failed."
fi

if [[ "$install_tailscale" =~ ^[Yy]$ ]]; then
    if [ -n "$tailscale_authkey" ]; then
        echo "Authenticating Tailscale..."
        tailscale up --authkey="$tailscale_authkey"
    else
        echo "Tailscale installed; run 'sudo tailscale up' to authenticate."
    fi
fi

if [[ "$do_reboot" =~ ^[Yy]$ ]]; then
    echo "Setup Complete. Rebooting in 7 seconds..."
    sleep 7
    reboot now
else
    echo "Setup Complete."
fi
