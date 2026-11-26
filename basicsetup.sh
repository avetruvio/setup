#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
DOTFILES_REPO="https://github.com/avetruvio/config.git"
LOG_FILE="/var/log/basicsetup.log"

# Defaults / CLI state
target_user=""
install_type=""
install_tailscale=""
tailscale_authkey="${TAILSCALE_AUTHKEY:-}"
github_keys_user=""
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
      --github-keys USER   Import public SSH keys from github.com/USER.keys
      --reboot             Reboot upon completion
      --no-reboot          Do not reboot upon completion
      --scp-dest DEST      SCP host-ini-info to DEST (e.g. user@host:/path/)
  -y, --yes                Non-interactive mode (use defaults for omitted options)
  -h, --help               Show this help message and exit
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -u|--user)          target_user="${2:?Missing argument for $1}"; shift 2 ;;
            -t|--type)          install_type="${2:?Missing argument for $1}"; shift 2 ;;
            --tailscale)        install_tailscale="y"; shift ;;
            --no-tailscale)     install_tailscale="n"; shift ;;
            --tailscale-key)    install_tailscale="y"; tailscale_authkey="${2:?Missing argument for $1}"; shift 2 ;;
            --github-keys)      github_keys_user="${2:?Missing argument for $1}"; shift 2 ;;
            --reboot)           do_reboot="y"; shift ;;
            --no-reboot)        do_reboot="n"; shift ;;
            --scp-dest)         scp_dest="${2:?Missing argument for $1}"; shift 2 ;;
            -y|--yes)           non_interactive=true; shift ;;
            -h|--help)          usage; exit 0 ;;
            *)                  echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

detect_distro() {
    DISTRO_ID="unknown"
    PKG_MGR=""
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
    fi

    local entry bin mgr
    for entry in apt-get:apt dnf:dnf yum:yum pacman:pacman zypper:zypper apk:apk; do
        bin="${entry%%:*}"
        mgr="${entry##*:}"
        if command -v "$bin" &>/dev/null; then
            PKG_MGR="$mgr"
            break
        fi
    done

    if [ -z "$PKG_MGR" ]; then
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
        apt)    apt-get update -y && apt-get upgrade -y ;;
        dnf)    dnf upgrade -y ;;
        yum)    yum update -y ;;
        pacman) pacman -Syu --noconfirm ;;
        zypper) zypper refresh && zypper update -y ;;
        apk)    apk update && apk upgrade ;;
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
            [ -n "$orphans" ] && echo "$orphans" | xargs pacman -Rns --noconfirm
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
        [ "$start_now" = "true" ] && { rc-service "$svc" start || true; }
    elif command -v service &>/dev/null && [ "$start_now" = "true" ]; then
        service "$svc" start || true
    fi
}

resolve_default_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER"
    elif [ -n "${DOAS_USER:-}" ]; then
        echo "$DOAS_USER"
    else
        logname 2>/dev/null || echo "root"
    fi
}

show_install_details() {
    cat <<EOF

=== Install Selection Details ===
Base (included in all modes):
  - System update/upgrade
  - openssh-server (or openssh), sudo, tmux, wget, git, curl, vim
  - software-properties-common (Ubuntu only)
  - Dotfiles from ${DOTFILES_REPO}

Role-specific packages:
  0 - Update only:         No extra role-specific packages
  1 - Headless server:     arp-scan
  2 - VPN headless server: openvpn, arp-scan
  3 - Netbook (i3):        i3/i3wm, i3lock, lightdm, lightdm-gtk-greeter, cool-retro-term (non-Alpine), picom/compton, xscreensaver
  4 - Desktop (i3):        Same as Netbook (i3 desktop stack)
  5 - VPS:                 openvpn
=================================

EOF
}

prompt_inputs() {
    local default_user
    default_user="$(resolve_default_user)"

    if [ -z "$target_user" ]; then
        if [ "$non_interactive" = true ]; then
            target_user="$default_user"
        else
            read -r -p "Enter username for dotfiles config [${default_user}]: " target_user
            target_user="${target_user:-$default_user}"
        fi
    fi

    if ! id "$target_user" &>/dev/null; then
        echo "Error: user '$target_user' does not exist."
        exit 1
    fi
    target_home="$(getent passwd "$target_user" | cut -d: -f6)"

    if [ -n "$install_type" ]; then
        if [[ ! "$install_type" =~ ^[0-5]$ ]]; then
            echo "Error: invalid install type '$install_type' (expected 0-5)."
            exit 1
        fi
    elif [ "$non_interactive" = true ]; then
        install_type="0"
    else
        while true; do
            cat <<EOF

Select install type (0-5, or ? for package details):
  0 - Update only (no role-specific packages)
  1 - Headless server
  2 - VPN headless server
  3 - Netbook (i3 desktop)
  4 - Desktop (i3 desktop)
  5 - VPS (OpenVPN)
  ? - Show detailed package list for each selection
EOF
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

    if [ -z "$github_keys_user" ] && [ "$non_interactive" = false ]; then
        read -r -p "Import GitHub SSH keys? Enter GitHub username (leave blank to skip): " github_keys_user
    fi

    if [ -z "$scp_dest" ] && [ "$non_interactive" = false ]; then
        read -r -p "SCP host-ini-info to central server? Enter destination (e.g. user@host:/path/) or leave blank to skip: " scp_dest
    fi

    if [ -z "$do_reboot" ]; then
        if [ "$non_interactive" = true ]; then
            do_reboot="n"
        else
            read -r -p "Reboot upon completion? (y/n): " do_reboot
        fi
    fi
}

install_base_packages() {
    local common_pkgs=(sudo tmux wget git curl vim)
    case "$PKG_MGR" in
        apt)
            pkg_install openssh-server "${common_pkgs[@]}"
            [ "$DISTRO_ID" = "ubuntu" ] && pkg_install software-properties-common
            enable_service ssh
            ;;
        dnf|yum)
            [ "$DISTRO_ID" != "fedora" ] && { pkg_install epel-release || true; }
            pkg_install openssh-server openssh-clients "${common_pkgs[@]}"
            enable_service sshd
            ;;
        pacman|zypper|apk)
            pkg_install openssh "${common_pkgs[@]}"
            enable_service sshd
            ;;
    esac
}

install_i3_desktop() {
    local common_i3=(i3lock lightdm lightdm-gtk-greeter xscreensaver)
    case "$PKG_MGR" in
        apt)
            if [ "$DISTRO_ID" = "ubuntu" ] && command -v add-apt-repository &>/dev/null; then
                add-apt-repository -y ppa:vantuz/cool-retro-term || true
                apt-get update -y
            fi
            local compositor_pkg="compton"
            apt-cache show picom &>/dev/null && compositor_pkg="picom"
            pkg_install i3 cool-retro-term "$compositor_pkg" "${common_i3[@]}" \
                xscreensaver-data xscreensaver-data-extra
            ;;
        dnf|yum)
            pkg_install i3 picom "${common_i3[@]}"
            pkg_install cool-retro-term || echo "Warning: cool-retro-term not available in configured repos, skipping."
            ;;
        pacman|zypper)
            pkg_install i3 cool-retro-term picom "${common_i3[@]}"
            ;;
        apk)
            pkg_install i3wm picom "${common_i3[@]}"
            ;;
    esac
    enable_service lightdm false
}

install_role_packages() {
    case "$install_type" in
        0)   echo "Update-only mode selected; skipping role-specific packages." ;;
        1)   pkg_install arp-scan ;;
        2)   pkg_install openvpn arp-scan ;;
        3|4) install_i3_desktop ;;
        5)   pkg_install openvpn ;;
    esac
}

install_dotfiles() {
    local user="$1"
    local home_dir="$2"
    local dotfiles_dir="${home_dir}/.dotfiles"

    echo "Installing dotfiles for ${user} in ${home_dir}..."
    if [ -d "$dotfiles_dir" ]; then
        echo "Dotfiles directory ${dotfiles_dir} already exists; skipping clone."
        return 0
    fi

    sudo -u "$user" /usr/bin/git clone --bare "$DOTFILES_REPO" "$dotfiles_dir"
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

install_ssh_keys() {
    local user="$1"
    local home_dir="$2"
    local gh_user="$3"
    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"
    local user_group
    user_group="$(id -gn "$user")"

    echo "Fetching GitHub SSH public keys for ${gh_user}..."
    local keys
    if ! keys="$(curl -fsSL "https://github.com/${gh_user}.keys" 2>/dev/null)" || [ -z "$keys" ]; then
        echo "Warning: Could not fetch SSH keys from GitHub for ${gh_user}; skipping."
        return 0
    fi

    mkdir -p "$ssh_dir"
    touch "$auth_keys"
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! grep -Fxq "$key" "$auth_keys"; then
            echo "$key" >> "$auth_keys"
        fi
    done <<< "$keys"

    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys"
    chown -R "${user}:${user_group}" "$ssh_dir"
    echo "SSH authorized_keys updated for ${user}."
}

write_and_send_host_info() {
    local info_file="${target_home}/host-ini-info"
    local host_name="${HOSTNAME:-$(hostname)}"
    local primary_ip
    primary_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"

    mkdir -p "$target_home"
    touch "$info_file"
    {
        echo "=== $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
        echo "Hostname: $host_name"
        echo "Distro: ${DISTRO_ID} (${PKG_MGR})"
        echo "User: $target_user"
        ip a | grep "scope global" || true
        echo ""
        echo "# SSH config snippet:"
        echo "Host ${host_name}"
        echo "    HostName ${primary_ip:-<IP_ADDRESS>}"
        echo "    User ${target_user}"
        echo ""
    } >> "$info_file"
    chown "${target_user}:$(id -gn "$target_user")" "$info_file"

    echo "Host info stored in ${info_file}."
    if [ -n "$scp_dest" ]; then
        scp "$info_file" "$scp_dest" || echo "Warning: scp to ${scp_dest} failed."
    fi
}

configure_tailscale() {
    [[ ! "$install_tailscale" =~ ^[Yy]$ ]] && return 0

    if [ -n "$tailscale_authkey" ]; then
        echo "Authenticating Tailscale..."
        tailscale up --authkey="$tailscale_authkey"
    else
        echo "Tailscale installed; run 'sudo tailscale up' to authenticate."
    fi
}

finish_setup() {
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
}

main() {
    parse_args "$@"

    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (e.g., sudo $0)"
        exit 1
    fi

    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    detect_distro
    prompt_inputs

    echo "Beginning setup, please stand by..."
    pkg_update
    install_base_packages
    install_role_packages

    if [[ "$install_tailscale" =~ ^[Yy]$ ]]; then
        curl -fsSL https://tailscale.com/install.sh | sh
        enable_service tailscaled
    else
        echo "Tailscale install bypassed, continuing..."
    fi

    if [ -n "$github_keys_user" ]; then
        install_ssh_keys "$target_user" "$target_home" "$github_keys_user"
    fi
    install_dotfiles "$target_user" "$target_home"
    pkg_cleanup
    write_and_send_host_info
    configure_tailscale
    finish_setup
}

main "$@"
