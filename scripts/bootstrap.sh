#!/usr/bin/env bash

set -euo pipefail

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [--no-run]

Options:
  -h | --help               Show this help message and exit.
  -p | --playbook FILE      Path to the playbook to run. Required if not using --no-run.
  -e | --extra-pkg NAME     Additional package to install alongside Ansible. May be specified multiple times.
  -l | --locale LOCALE      Use the specified locale for the system (default: en_US.UTF-8).
  -v | --var NAME=VALUE     Pass a variable to the playbook. May be specified multiple times.
  --no-run                  Skip running the playbook after bootstrapping.
  --no-upgrade              Skip the system upgrade step.

Environment variables:
  PLAYBOOK
  DEFAULT_LOCALE
  NO_RUN
  NO_UPGRADE
EOF
  exit 1
}

OPTS=$(getopt -o h,p:e:v:n,l: -l help,playbook:,extra-pkg:,var:,no-run,locale:,no-upgrade -n "$0" -- "$@") || usage
eval set -- "$OPTS"

PLAYBOOK=""
EXTRA_PACKAGES=()
EXTRA_VARS=()
DEFAULT_LOCALE="en_US.UTF-8"
NO_RUN=0
NO_UPGRADE=0

while true; do
  case "$1" in
    -h|--help)
      usage
      ;;
    -p|--playbook)
      PLAYBOOK="$2"
      shift 2
      ;;
    -e|--extra-pkg)
      EXTRA_PACKAGES+=( "$2" )
      shift 2
      ;;
    -v|--var)
      EXTRA_VARS+=("$2")
      shift 2
      ;;
    -n|--no-run)
      NO_RUN=1
      shift
      ;;
    --no-upgrade)
      NO_UPGRADE=1
      shift
      ;;
    -l|--locale)
      DEFAULT_LOCALE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done


# --- 1. Ensure root privileges ------------------------------------------------
# Re-exec ourselves with sudo so the whole script (and the playbook) runs as root.
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  die "Run this script as root (e.g. 'sudo bash bootstrap.sh')."
fi

# --- 2. Sanity checks -----------------------------------------------------------
if [[ "$NO_RUN" -ne 1 ]]; then
  if [[ -z "$PLAYBOOK" ]]; then
    die "Playbook not provided. Use -p or --playbook to specify the playbook."
  elif [[ ! -r "$PLAYBOOK" ]]; then
    die "The provided playbook is not readable: $PLAYBOOK"
  fi
fi

[[ -f /etc/os-release ]] || die "Cannot determine the OS (/etc/os-release missing)."
if ! grep -qi '^ID=arch' /etc/os-release; then
  # shellcheck source=/dev/null
  die "This bootstrap script targets Arch Linux only (got: $(. /etc/os-release && echo "$ID"))."
fi

# --- 3. Refresh pacman keyring and fully upgrade --------------------------------
# Just in case the pacman keyring is somehow missing, initialize it.
if [[ ! -d /etc/pacman.d/gnupg ]]; then
  log "Initialising pacman keyring..."
  pacman-key --init
  pacman-key --populate archlinux
  pacman -Sy --noconfirm archlinux-keyring
fi

# Deal with locales.
sed -i "s/^#${DEFAULT_LOCALE} UTF-8/${DEFAULT_LOCALE} UTF-8/" /etc/locale.gen
locale-gen
if [[ ! -f /etc/locale.conf ]] || ! grep -q "^LANG=${DEFAULT_LOCALE}$" /etc/locale.conf; then
  printf 'LANG=%s\n' "$DEFAULT_LOCALE" > /etc/locale.conf
fi
export LANG="$DEFAULT_LOCALE"

if [[ "$NO_UPGRADE" -eq 1 ]]; then
  log "Updating pacman package database..."
  pacman -Sy --noconfirm
else
  log "Upgrading system packages..."
  pacman -Syu --noconfirm
fi

# --- 4. Install Ansible and prerequisites ----------------------------------------
log "Installing Ansible and prerequisites..."
pacman -S --noconfirm --needed python ansible sudo "${EXTRA_PACKAGES[@]}"

command -v ansible >/dev/null 2>&1 || die "Ansible was not installed successfully."
log "Ansible ready: $(ansible --version | head -n1)"

# Drop unneeded package tarballs from the upgrade + install to keep the rootfs lean.
log "Cleaning package cache..."
pacman -Sc --noconfirm

# --- 5. Kick off the deployment (optional) ---------------------------------------
if [[ "$NO_RUN" -eq 1 ]]; then
  log "\nSystem ready to run Ansible playbooks."
  exit 0
fi

log "Running deployment playbook: $PLAYBOOK"

ansibleArgs=()
if [ ${#EXTRA_VARS[@]} -gt 0 ]; then
  ansibleArgs+=("--extra-vars" "${EXTRA_VARS[*]}")
fi

ansible-playbook -i localhost, --connection=local "$PLAYBOOK" "${ansibleArgs[@]}"
if [[ "$?" -ne 0 ]]; then
  die "Deployment playbook failed with exit code $?."
fi
