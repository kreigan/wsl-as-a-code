#!/usr/bin/env bash
#
# bootstrap.sh - Bootstrap a clean Arch Linux system to run the Ansible deployment.
#
# Usage:
#   ./bootstrap.sh              # install prerequisites and run the playbook
#   ./bootstrap.sh --no-run     # install prerequisites only
#
# Environment overrides:
#   PLAYBOOK            path to the playbook to run (default: ansible/bootstrap.yml)
#   INSTALL_EXTRA       extra space-separated packages to install alongside Ansible
#   FORCE_KEYRING_INIT  set to 1 to always run pacman-key --init/--populate
#   DEFAULT_LOCALE      locale to generate and set (default: en_US.UTF-8)
#   REFRESH_MIRRORS     set to 0 to skip reflector mirror refresh (default: on)
#   MIRROR_COUNTRY      restrict reflector to a country code (e.g. "France")
#
set -euo pipefail

PLAYBOOK="${PLAYBOOK:-ansible/bootstrap.yml}"
EXTRA_PACKAGES="${INSTALL_EXTRA:-}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Ensure root privileges ------------------------------------------------
# Re-exec ourselves with sudo so the whole script (and the playbook) runs as root.
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    die "Run this script as root (e.g. 'sudo bash bootstrap.sh')."
fi

# --- 2. Sanity checks -----------------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot determine the OS (/etc/os-release missing)."
if ! grep -qi '^ID=arch' /etc/os-release; then
    # shellcheck source=/dev/null
    die "This bootstrap script targets Arch Linux only (got: $(. /etc/os-release && echo "$ID"))."
fi

# --- 3. Refresh pacman keyring and fully upgrade --------------------------------
# The official Arch WSL distro already runs `pacman-key --init` and
# `pacman-key --populate archlinux` on its first launch, so we only redo that
# when the keyring is missing entirely (e.g. a manually imported rootfs or the
# legacy ArchWSL distro, where it is a required manual step). Redoing it is
# safe and idempotent, but unnecessary for the official distro.
if [[ ! -d /etc/pacman.d/gnupg || "${FORCE_KEYRING_INIT:-0}" == "1" ]]; then
    log "Initialising pacman keyring..."
    pacman-key --init
    pacman-key --populate archlinux
else
    log "Pacman keyring already initialised (skipping pacman-key --init/--populate)."
fi

# A freshly installed distro usually ships an out-of-date archlinux-keyring,
# which breaks signature checks during the upgrade. Refresh it first, then do
# the full dist-upgrade.
log "Refreshing archlinux-keyring..."
pacman -Sy --noconfirm archlinux-keyring

# Optional: pick fast, up-to-date mirrors before the big upgrade. This installs
# reflector and queries the Arch mirror status API, so it needs network and may
# take a few seconds. Disable with REFRESH_MIRRORS=0.
if [[ "${REFRESH_MIRRORS:-1}" == "1" ]]; then
    log "Refreshing pacman mirror list (reflector)..."
    pacman -S --noconfirm --needed reflector
    REFLECTOR_ARGS=(--latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist)
    if [[ -n "${MIRROR_COUNTRY:-}" ]]; then
        REFLECTOR_ARGS=(--country "$MIRROR_COUNTRY" "${REFLECTOR_ARGS[@]}")
    fi
    if reflector "${REFLECTOR_ARGS[@]}"; then
        pacman -Syy
        log "Mirror list refreshed."
    else
        warn "Reflector failed — keeping the existing mirror list."
    fi
fi

# Deal with locales.
DEFAULT_LOCALE="${DEFAULT_LOCALE:-en_US.UTF-8}"
sed -i "s/^#${DEFAULT_LOCALE} UTF-8/${DEFAULT_LOCALE} UTF-8/" /etc/locale.gen
locale-gen
if [[ ! -f /etc/locale.conf ]] || ! grep -q "^LANG=${DEFAULT_LOCALE}$" /etc/locale.conf; then
    printf 'LANG=%s\n' "$DEFAULT_LOCALE" > /etc/locale.conf
fi
export LANG="$DEFAULT_LOCALE"
log "Locale ready: ${DEFAULT_LOCALE}"

log "Upgrading the entire system..."
pacman -Syu --noconfirm

# --- 4. Install Ansible and prerequisites ----------------------------------------
log "Installing Ansible and prerequisites..."
# shellcheck disable=SC2086
pacman -S --noconfirm --needed python ansible sudo git openssh $EXTRA_PACKAGES

command -v ansible >/dev/null 2>&1 || die "Ansible was not installed successfully."
log "Ansible ready: $(ansible --version | head -n1)"

# --- 5. OS hygiene -------------------------------------------------------------
# Keep the system clock in sync.
if [[ -d /run/systemd/system ]]; then
    log "Enabling time synchronization..."
    timedatectl set-ntp true || warn "Could not enable NTP (ignoring)."
else
    warn "systemd not running — skipping NTP setup (WSL syncs the clock from the host)."
fi

# Drop unneeded package tarballs from the upgrade + install to keep the rootfs lean.
log "Cleaning package cache..."
pacman -Sc --noconfirm

# --- 6. Kick off the deployment (optional) ---------------------------------------
run_playbook=true
case "${1:-}" in
    --no-run|-n) run_playbook=false ;;
    "")       ;;
    *)        die "Unknown argument: $1 (expected '--no-run' or nothing)" ;;
esac

if $run_playbook; then
    [[ -f "$PLAYBOOK" ]] || die "Playbook not found: $PLAYBOOK (are you in the repo root?)"
    log "Running deployment playbook: $PLAYBOOK"
    ansible-playbook -i localhost, --connection=local "$PLAYBOOK"
else
    log "Bootstrap complete. Deploy with:"
    log "  ansible-playbook -i localhost, --connection=local $PLAYBOOK"
fi
