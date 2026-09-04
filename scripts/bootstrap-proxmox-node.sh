#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${USER_NAME:-sisyphus}"
USER_ID="${USER_ID:-3004}"
GROUP_ID="${GROUP_ID:-3004}"
LEGACY_STORAGE_ROOT="${LEGACY_STORAGE_ROOT:-/mnt/legacy-storage}"
STORAGE_ROOT="${STORAGE_ROOT:-/mnt/storage}"
PERSONAL_ROOT="${PERSONAL_ROOT:-/mnt/personal}"
APPDATA_ROOT="${APPDATA_ROOT:-${STORAGE_ROOT}/appdata}"

VALID_STACKS=(
  aeos
  apollo
  asteria
  atlas
  helios
  hera
  io
)

usage() {
  cat <<EOF
Usage: sudo $0 <stack-name>

Bootstraps a Proxmox/Debian container with Docker, Tailscale, git, zsh,
Antigen, zsh-syntax-highlighting, zoxide, and the ${USER_NAME} service user.

Expected mount layout:
  Source dataset on Proxmox host: /mnt/lxc_shares/storage
  Source dataset in container:    /mnt/legacy-storage
  Target dataset on Proxmox host: /mnt/lxc_shares/sisyphus
  Target dataset in container:    /mnt/storage
  Optional personal data:         /mnt/personal

Arguments:
  stack-name       One of: ${VALID_STACKS[*]}

Environment:
  LEGACY_STORAGE_ROOT  Source storage mount. Default: ${LEGACY_STORAGE_ROOT}
  STORAGE_ROOT         Target storage mount. Default: ${STORAGE_ROOT}
  PERSONAL_ROOT        Personal storage mount. Default: ${PERSONAL_ROOT}
  APPDATA_ROOT         Appdata root path. Default: ${APPDATA_ROOT}
  USER_NAME            Service user name. Default: ${USER_NAME}
  USER_ID              Service user UID. Default: ${USER_ID}
  GROUP_ID             Service user GID. Default: ${GROUP_ID}

Example:
  sudo $0 asteria
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run this script as root, for example: sudo $0 ${1:-asteria}"
  fi
}

validate_stack() {
  local stack_name="$1"
  local valid_stack

  [[ -n "${stack_name}" ]] || {
    usage
    exit 2
  }

  for valid_stack in "${VALID_STACKS[@]}"; do
    if [[ "${stack_name}" == "${valid_stack}" ]]; then
      return 0
    fi
  done

  usage
  die "unknown stack '${stack_name}'"
}

install_base_packages() {
  log "Installing git, zsh, curl, and zoxide"
  apt-get update
  apt-get install -y ca-certificates curl git gnupg sudo zsh zoxide
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed"
  else
    log "Installing Docker from get.docker.com"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  fi
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale is already installed"
    return 0
  fi

  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
}

ensure_group() {
  if getent group "${USER_NAME}" >/dev/null 2>&1; then
    local existing_gid
    existing_gid="$(getent group "${USER_NAME}" | cut -d: -f3)"
    [[ "${existing_gid}" == "${GROUP_ID}" ]] ||
      die "group '${USER_NAME}' exists with GID ${existing_gid}, expected ${GROUP_ID}"
    return 0
  fi

  if getent group "${GROUP_ID}" >/dev/null 2>&1; then
    die "GID ${GROUP_ID} is already used by group '$(getent group "${GROUP_ID}" | cut -d: -f1)'"
  fi

  log "Creating group ${USER_NAME}:${GROUP_ID}"
  groupadd --gid "${GROUP_ID}" "${USER_NAME}"
}

ensure_user() {
  local zsh_path
  zsh_path="$(command -v zsh)"

  if id "${USER_NAME}" >/dev/null 2>&1; then
    local existing_uid existing_gid
    existing_uid="$(id -u "${USER_NAME}")"
    existing_gid="$(id -g "${USER_NAME}")"
    [[ "${existing_uid}" == "${USER_ID}" ]] ||
      die "user '${USER_NAME}' exists with UID ${existing_uid}, expected ${USER_ID}"
    [[ "${existing_gid}" == "${GROUP_ID}" ]] ||
      die "user '${USER_NAME}' exists with GID ${existing_gid}, expected ${GROUP_ID}"
    log "User ${USER_NAME} already exists"
  else
    log "Creating user ${USER_NAME}:${USER_ID} with home directory"
    useradd \
      --uid "${USER_ID}" \
      --gid "${GROUP_ID}" \
      --create-home \
      --home-dir "/home/${USER_NAME}" \
      --shell "${zsh_path}" \
      "${USER_NAME}"
  fi

  usermod --shell "${zsh_path}" "${USER_NAME}"
  usermod --shell "${zsh_path}" root
  usermod --append --groups docker "${USER_NAME}"
  chown "${USER_ID}:${GROUP_ID}" "/home/${USER_NAME}"
}

install_antigen() {
  local antigen_file="/root/antigen.zsh"

  if [[ -f "${antigen_file}" ]]; then
    log "Antigen is already installed"
    return 0
  fi

  log "Installing Antigen"
  curl -L git.io/antigen >"${antigen_file}"
  chmod 0644 "${antigen_file}"
}

configure_zsh() {
  local zshrc="/root/.zshrc"

  log "Configuring root zsh with Antigen and zsh-syntax-highlighting"
  cat >"${zshrc}" <<'EOF'
source /root/antigen.zsh

# Load the oh-my-zsh's library.
antigen use oh-my-zsh

# Bundles from the default repo (robbyrussell's oh-my-zsh).
antigen bundle git
antigen bundle heroku
antigen bundle pip
antigen bundle lein
antigen bundle command-not-found

# Syntax highlighting bundle.
antigen bundle zsh-users/zsh-syntax-highlighting

# Load the theme.
antigen theme robbyrussell

# Tell Antigen that you're done.
antigen apply
EOF

  chown root:root "${zshrc}"
  chmod 0644 "${zshrc}"
}

ensure_mount() {
  local container_path="$1"
  local host_path="$2"
  local label="$3"

  log "Verifying ${label} mount ${container_path}"

  [[ -d "${container_path}" ]] ||
    die "${container_path} does not exist; bind-mount ${host_path} from the Proxmox host first"

  if command -v findmnt >/dev/null 2>&1; then
    findmnt -T "${container_path}" >/dev/null ||
      die "${container_path} is not mounted; expected container bind mount for host ${host_path}"
  elif command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "${container_path}" ||
      die "${container_path} is not mounted; expected container bind mount for host ${host_path}"
  else
    log "Could not verify mount status because neither findmnt nor mountpoint is available"
  fi
}

ensure_storage_mounts() {
  ensure_mount "${LEGACY_STORAGE_ROOT}" "/mnt/lxc_shares/storage" "source storage"
  ensure_mount "${STORAGE_ROOT}" "/mnt/lxc_shares/sisyphus" "target storage"
}

ensure_stack_link() {
  local stack_name="$1"
  local target="${APPDATA_ROOT}/${stack_name}"
  local link="/home/${USER_NAME}/${stack_name}"

  log "Preparing appdata directory ${target}"
  install -d -o "${USER_ID}" -g "${GROUP_ID}" -m 0775 "${target}"

  if [[ -L "${link}" ]]; then
    local current_target
    current_target="$(readlink "${link}")"
    [[ "${current_target}" == "${target}" ]] ||
      die "${link} is already a symlink to ${current_target}, expected ${target}"
    log "Stack symlink already exists: ${link} -> ${target}"
    return 0
  fi

  if [[ -e "${link}" ]]; then
    die "${link} already exists and is not a symlink; move it aside before rerunning"
  fi

  log "Creating stack symlink ${link} -> ${target}"
  ln -s "${target}" "${link}"
  chown -h "${USER_ID}:${GROUP_ID}" "${link}"
}

main() {
  local stack_name="${1:-}"

  if [[ "${stack_name}" == "-h" || "${stack_name}" == "--help" ]]; then
    usage
    exit 0
  fi

  validate_stack "${stack_name}"
  require_root "${stack_name}"
  install_base_packages
  install_docker
  install_tailscale
  ensure_group
  ensure_user
  install_antigen
  configure_zsh
  ensure_storage_mounts
  ensure_stack_link "${stack_name}"

  log "Bootstrap complete"
  printf 'User: %s (%s:%s)\n' "${USER_NAME}" "${USER_ID}" "${GROUP_ID}"
  printf 'Stack link: /home/%s/%s -> %s/%s\n' \
    "${USER_NAME}" "${stack_name}" "${APPDATA_ROOT}" "${stack_name}"
  cat <<EOF

Next manual steps:
  zsh
  tailscale up
EOF
}

main "$@"
