#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

target_user=""
install_type=""
install_tailscale=""
tailscale_authkey="${TAILSCALE_AUTHKEY:-}"
do_reboot=""
scp_dest=""
non_interactive=false

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  -u, --user USER          Target username for dotfiles and host-ini-info
  -t, --type MODE          Install mode (0-5):
                             0=update only, 1=headless, 2=vpn headless,
                             3=netbook (i3), 4=desktop (i3), 5=vps
      --tailscale          Install Tailscale
      --no-tailscale       Skip Tailscale installation
      --tailscale-key KEY  Tailscale auth key (implies --tailscale)
      --reboot             Reboot upon completion
      --no-reboot          Do not reboot upon completion
      --scp-dest DEST      SCP host-ini-info to DEST (e.g. user@host:/path/)
  -y, --yes                Non-interactive mode (use defaults for omitted options)
  -h, --help               Show this help message and exit
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)          target_user="${2:?Missing argument for $1}"; shift 2 ;;
        -t|--type)          install_type="${2:?Missing argument for $1}"; shift 2 ;;
        --tailscale)        install_tailscale="y"; shift ;;
        --no-tailscale)     install_tailscale="n"; shift ;;
        --tailscale-key)    install_tailscale="y"; tailscale_authkey="${2:?Missing argument for $1}"; shift 2 ;;
        --reboot)           do_reboot="y"; shift ;;
        --no-reboot)        do_reboot="n"; shift ;;
        --scp-dest)         scp_dest="${2:?Missing argument for $1}"; shift 2 ;;
        -y|--yes)           non_interactive=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

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

    if [ "$PKG_MGR" = "apk" ] && [ -f /etc/apk/repositories ]; then
        sed -i -E 's|^#(.*community)|\1|' /etc/apk/repositories
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

enable_service() {
    local svc="$1"
    local start_now="${2:-true}"

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        if [ "$start_now" = "true" ]; then
            systemctl enable --now "$svc" || true
        else
            systemctl enable "$svc" || true
        fi
    elif command -v rc-update &>/dev/null; then
        rc-update add "$svc" default || true
        if [ "$start_now" = "true" ]; then
            rc-service "$svc" start || true
        fi
    elif command -v service &>/dev/null && [ "$start_now" = "true" ]; then
        service "$svc" start || true
    fi
}

detect_distro

if [ -n "${SUDO_USER:-}" ]; then
    DEFAULT_USER="$SUDO_USER"
elif [ -n "${DOAS_USER:-}" ]; then
    DEFAULT_USER="$DOAS_USER"
else
    DEFAULT_USER="$(logname 2>/dev/null || echo "root")"
fi
if [ -z "$target_user" ]; then
    if [ "$non_interactive" = true ]; then
        target_user="$DEFAULT_USER"
    else
        read -r -p "Enter username for dotfiles config [${DEFAULT_USER}]: " target_user
        target_user="${target_user:-$DEFAULT_USER}"
    fi
fi

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
    echo "  - openssh-server (or openssh), sudo, tmux, wget, git, curl, vim, ansible"
    echo "  - software-properties-common (Ubuntu only)"
    echo "  - Dotfiles from https://github.com/avetruvio/config.git"
    echo ""
    echo "Role-specific packages:"
    echo "  0 - Update only:         No extra role-specific packages"
    echo "  1 - Headless server:     arp-scan"
    echo "  2 - VPN headless server: openvpn, arp-scan"
    echo "  3 - Netbook (i3):        i3/i3wm, i3lock, lightdm, lightdm-gtk-greeter, cool-retro-term (non-Alpine), picom/compton, xscreensaver"
    echo "  4 - Desktop (i3):        Same as Netbook (i3 desktop stack)"
    echo "  5 - VPS:                 openvpn"
    echo "================================="
    echo ""
}

if [ -n "$install_type" ]; then
    if [[ ! "$install_type" =~ ^[0-5]$ ]]; then
        echo "Error: invalid install type '$install_type' (expected 0-5)."
        exit 1
    fi
elif [ "$non_interactive" = true ]; then
    install_type="0"
else
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
        read -r -p "Choice [0-5, ?]: " install_type

        case "$install_type" in
            [0-5]) break ;;
            \?)    show_install_details ;;
            *)     echo "Invalid choice '$install_type'. Please enter 0-5 or ?." ;;
        esac
    done
fi

if [ -z "$install_tailscale" ]; then
    if [ "$non_interactive" = true ]; then
        install_tailscale="n"
    else
        read -r -p "Install Tailscale? (y/n): " install_tailscale
    fi
fi

if [[ "$install_tailscale" =~ ^[Yy]$ ]] && [ -z "$tailscale_authkey" ] && [ "$non_interactive" = false ]; then
    read -r -s -p "Enter Tailscale auth key (leave blank to skip): " tailscale_authkey
    echo ""
fi

if [ -z "$do_reboot" ]; then
    if [ "$non_interactive" = true ]; then
        do_reboot="n"
    else
        read -r -p "Reboot upon completion? (y/n): " do_reboot
    fi
fi

echo "Beginning setup, please stand by..."
pkg_update

case "$PKG_MGR" in
    apt)
        pkg_install openssh-server sudo tmux wget git curl vim ansible
        if [ "$DISTRO_ID" = "ubuntu" ]; then
            pkg_install software-properties-common
        fi
        enable_service ssh
        ;;
    dnf|yum)
        if [ "$DISTRO_ID" != "fedora" ]; then
            pkg_install epel-release || true
        fi
        pkg_install openssh-server openssh-clients sudo tmux wget git curl vim ansible
        enable_service sshd
        ;;
    pacman|zypper|apk)
        pkg_install openssh sudo tmux wget git curl vim ansible
        enable_service sshd
        ;;
esac

install_i3_desktop() {
    case "$PKG_MGR" in
        apt)
            if [ "$DISTRO_ID" = "ubuntu" ] && command -v add-apt-repository &>/dev/null; then
                add-apt-repository -y ppa:vantuz/cool-retro-term || true
                apt-get update -y
            fi
            local compositor_pkg="compton"
            if apt-cache show picom &>/dev/null; then
                compositor_pkg="picom"
            fi
            pkg_install i3 i3lock lightdm lightdm-gtk-greeter cool-retro-term "$compositor_pkg" \
                xscreensaver xscreensaver-data xscreensaver-data-extra
            ;;
        dnf|yum)
            pkg_install i3 i3lock lightdm lightdm-gtk-greeter picom xscreensaver
            pkg_install cool-retro-term || echo "Warning: cool-retro-term not available in configured repos, skipping."
            ;;
        pacman|zypper)
            pkg_install i3 i3lock lightdm lightdm-gtk-greeter cool-retro-term picom xscreensaver
            ;;
        apk)
            pkg_install i3wm i3lock lightdm lightdm-gtk-greeter picom xscreensaver
            ;;
    esac
    enable_service lightdm false
}

case "$install_type" in
    0)
        echo "Update-only mode selected; skipping role-specific packages."
        ;;
    1)
        pkg_install arp-scan
        ;;
    2)
        pkg_install openvpn arp-scan
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
    enable_service tailscaled
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
        while IFS= read -r conflict_file; do
            [ -n "$conflict_file" ] && rm -f "${home_dir}/${conflict_file}"
        done < <("${git_cmd[@]}" checkout 2>&1 | grep -E "^\s+\." | awk '{print $1}')
        "${git_cmd[@]}" checkout
    fi

    "${git_cmd[@]}" config --local status.showUntrackedFiles no
    echo "Dotfiles install successful."
}

install_dotfiles "$target_user" "$target_home"

pkg_cleanup

info_file="${target_home}/host-ini-info"
host_name="${HOSTNAME:-$(hostname)}"
mkdir -p "$target_home"
touch "$info_file"
{
    echo "=== $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
    echo "Hostname: $host_name"
    echo "Distro: ${DISTRO_ID} (${PKG_MGR})"
    echo "User: $target_user"
    ip a | grep "scope global" || true
    echo ""
} >> "$info_file"
chown "${target_user}:$(id -gn "$target_user")" "$info_file"

echo "Host info stored in ${info_file}."
if [ -z "$scp_dest" ] && [ "$non_interactive" = false ]; then
    read -r -p "SCP host-ini-info to central server? Enter destination (e.g. user@host:/path/) or leave blank to skip: " scp_dest
fi
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
    echo "Setup Complete."
    for i in {7..1}; do
        printf "\rRebooting in %d second(s)... (Ctrl+C to cancel) " "$i"
        sleep 1
    done
    echo ""
    rm -f -- "$SCRIPT_PATH"
    reboot now
else
    rm -f -- "$SCRIPT_PATH"
    echo "Setup Complete."
fi
