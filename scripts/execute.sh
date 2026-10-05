#!/usr/bin/env bash

set -euo pipefail

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 <SUBCOMMAND> [ARGS...]

Subcommands:
  bootstrap                 Install the minimum required packages to run Ansible.
  playbook NAME [OPTIONS]   Run a playbook from ansible/ directory, passing OPTIONS to ansible-playbook.

Options:
  -h | --help               Show this help message and exit.
EOF
}

bootstrap() {
  [[ -f /etc/os-release ]] || die "Cannot determine the OS (/etc/os-release missing)."
  local os_id
  os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
  [[ -n "$os_id" ]] || os_id="unknown"
  [[ "$os_id" == "arch" ]] || die "This bootstrap script targets Arch Linux only (got: $os_id)."

  log "Initialising pacman keyring..."
  pacman-key --init > /dev/null 2>&1
  pacman-key --populate archlinux > /dev/null 2>&1
  pacman -Sy --noconfirm archlinux-keyring > /dev/null 2>&1

  log "Installing Ansible and its runtime prerequisites..."
  pacman -Sy --noconfirm --needed python ansible sudo

  command -v ansible >/dev/null 2>&1 || die "Ansible was not installed successfully."
  command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook was not installed successfully."
  log "Ansible ready: $(ansible --version | head -n1)"
}

playbook() {
  [[ $# -gt 0 ]] || die "Playbook name or path required. Usage: $0 playbook NAME|PATH [OPTIONS]"
  local playbook_file="$1"

  if [[ ! -f "$playbook_file" ]]; then
    playbook_file="$(dirname "$0")/ansible/$1.yml"
  fi
  shift

  if [[ ! -r "$playbook_file" ]]; then
    die "The provided playbook is not readable: $playbook_file"
  fi

  command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook is not installed. Run '$0 bootstrap' first."
  log "Running playbook: $playbook_file"
  ansible-playbook -i localhost, --connection=local "$playbook_file" "$@"
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

subcommand="$1"
shift
case "$subcommand" in
  -h|--help)
    usage
    ;;
  bootstrap)
    [[ $# -eq 0 ]] || die "The bootstrap subcommand does not accept arguments."
    bootstrap
    ;;
  playbook)
    playbook "$@"
    ;;
  *)
    usage >&2
    die "Unknown subcommand: $subcommand"
    ;;
esac
