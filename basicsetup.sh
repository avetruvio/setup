#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (e.g., sudo $0)"
    exit 1
fi

detect_distro() {
    DISTRO_ID="unknown"
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
    fi

    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"
    else
        echo "Error: No supported package manager found (detected distro: ${DISTRO_ID})."
        exit 1
    fi

    echo "Detected distro: ${DISTRO_ID} (package manager: ${PKG_MGR})"
}

pkg_update() {
    case "$PKG_MGR" in
        apt)
            apt-get update -y
            apt-get upgrade -y
            ;;
        dnf)    dnf upgrade -y ;;
        yum)    yum update -y ;;
        pacman) pacman -Syu --noconfirm ;;
        zypper)
            zypper refresh
            zypper update -y
            ;;
        apk)
            apk update
            apk upgrade
            ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apt)    apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        zypper) zypper install -y "$@" ;;
        apk)    apk add --no-cache "$@" ;;
    esac
}

pkg_cleanup() {
    case "$PKG_MGR" in
        apt) apt-get autoremove -y ;;
        dnf) dnf autoremove -y ;;
        yum) yum autoremove -y ;;
        pacman)
            local orphans
            orphans="$(pacman -Qtdq 2>/dev/null || true)"
            if [ -n "$orphans" ]; then
                echo "$orphans" | xargs pacman -Rns --noconfirm
            fi
            ;;
        zypper|apk) ;;
    esac
}

detect_distro

DEFAULT_USER="${SUDO_USER:-root}"
read -r -p "Enter username for dotfiles config [${DEFAULT_USER}]: " target_user
target_user="${target_user:-$DEFAULT_USER}"

if ! id "$target_user" &>/dev/null; then
    echo "Error: user '$target_user' does not exist."
    exit 1
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6)"

show_install_details() {
    echo ""
    echo "=== Install Selection Details ==="
    echo "Base (included in all modes):"
    echo "  - System update/upgrade"
    echo "  - openssh-server (or openssh), tmux, wget, git, curl"
    echo "  - software-properties-common (apt only)"
    echo "  - Dotfiles from https://github.com/avetruvio/config.git"
    echo ""
    echo "Role-specific packages:"
    echo "  0 - Update only:         No extra role-specific packages"
    echo "  1 - Headless server:     easyrsa/easy-rsa, arp-scan"
    echo "  2 - VPN headless server: openvpn, easyrsa/easy-rsa, arp-scan"
    echo "  3 - Netbook (i3):        i3, i3lock, lightdm, cool-retro-term, compton/picom, xscreensaver"
    echo "  4 - Desktop (i3):        Same as Netbook (i3 desktop stack)"
    echo "  5 - VPS:                 openvpn"
    echo "================================="
    echo ""
}

while true; do
    echo ""
    echo "Select install type (0-5, or ? for package details):"
    echo "  0 - Update only (no role-specific packages)"
    echo "  1 - Headless server"
    echo "  2 - VPN headless server"
    echo "  3 - Netbook (i3 desktop)"
    echo "  4 - Desktop (i3 desktop)"
    echo "  5 - VPS (OpenVPN)"
    echo "  ? - Show detailed package list for each selection"
    read -r -n 1 -p "Choice [0-5, ?]: " install_type
    echo ""

    case "$install_type" in
        [0-5]) break ;;
        \?)    show_install_details ;;
        *)     echo "Invalid choice '$install_type'. Please enter 0-5 or ?." ;;
    esac
done

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
pkg_update

case "$PKG_MGR" in
    apt)
        pkg_install openssh-server tmux wget git curl software-properties-common
        easyrsa_pkg="easyrsa"
        ;;
    dnf|yum)
        pkg_install openssh-server tmux wget git curl
        easyrsa_pkg="easy-rsa"
        ;;
    pacman|zypper|apk)
        pkg_install openssh tmux wget git curl
        easyrsa_pkg="easy-rsa"
        ;;
esac

install_i3_desktop() {
    case "$PKG_MGR" in
        apt)
            if [ "$DISTRO_ID" = "ubuntu" ] && command -v add-apt-repository &>/dev/null; then
                add-apt-repository -y ppa:vantuz/cool-retro-term || true
                apt-get update -y
            fi
            pkg_install i3 i3lock lightdm cool-retro-term compton \
                xscreensaver xscreensaver-data xscreensaver-data-extra
            ;;
        *)
            pkg_install i3 i3lock lightdm cool-retro-term picom xscreensaver
            ;;
    esac
}

case "$install_type" in
    0)
        echo "Update-only mode selected; skipping role-specific packages."
        ;;
    1)
        pkg_install "$easyrsa_pkg" arp-scan
        ;;
    2)
        pkg_install openvpn "$easyrsa_pkg" arp-scan
        ;;
    3|4)
        install_i3_desktop
        ;;
    5)
        pkg_install openvpn
        ;;
    *)
        echo "Invalid install type '$install_type'; skipping role-specific packages."
        ;;
esac

if [[ "$install_tailscale" =~ ^[Yy]$ ]]; then
    curl -fsSL https://tailscale.com/install.sh | sh
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

pkg_cleanup

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
