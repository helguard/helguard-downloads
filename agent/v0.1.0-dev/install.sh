#!/usr/bin/env bash

set -euo pipefail

readonly PRODUCT_NAME="Helguard"
readonly TOOL_NAME="Helguard Agent"
readonly INSTALLER_VERSION="v0.1.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly PACKAGE_NAME_AMD64="helguard-agent-linux-amd64.tar.gz"
readonly PACKAGE_NAME_ARM64="helguard-agent-linux-arm64.tar.gz"
readonly PACKAGE_BASE_URL_DEFAULT="https://github.com/helguard/helguard-agent/releases/download/v0.1.0-dev"
readonly WORK_DIR_DEFAULT="/tmp/helguard-bootstrap"
readonly EXTRACT_DIR_NAME="package"
readonly PACKAGE_ROOT_DIR_NAME="helguard-agent"

PACKAGE_URL=""
PACKAGE_NAME=""
CHECKSUM_URL=""
CHECKSUM_NAME=""
ARCH=""
WORK_DIR="${WORK_DIR_DEFAULT}"
NODE_ID=""
API_KEY=""
DRY_RUN=false
UNINSTALL_MODE=false

print_line() {
  printf '%s\n' "$1"
}

print_error() {
  printf 'ERROR: %s\n' "$1" >&2
}

print_warn() {
  printf 'WARN: %s\n' "$1" >&2
}

assert_root_access() {
  if [[ "${EUID}" -ne 0 ]]; then
    print_error "This installer must be run as root."
    print_error "Try: sudo ./installer.sh"
    exit 1
  fi
}

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Bootstrap installer for ${TOOL_NAME}.

Options:
  --package-url <url>  Override package URL
  --work-dir <path>    Override temporary working directory
  --node-id <id>       Node identifier for auto enrollment
  --api-key <key>      API key for auto enrollment
  --uninstall          Run package uninstall.sh instead of install flow
  -n, --dry-run        Print actions without executing install
  -h, --help           Show this help message
EOF
}

read_option_value() {
  local option_name="$1"
  local option_value="${2:-}"

  if [[ -z "${option_value}" || "${option_value}" == -* ]]; then
    print_error "Missing value for ${option_name}"
    exit 1
  fi

  print_line "${option_value}"
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --package-url)
        PACKAGE_URL="$(read_option_value "$1" "${2:-}")"
        shift 2
        ;;
      --work-dir)
        WORK_DIR="$(read_option_value "$1" "${2:-}")"
        shift 2
        ;;
      --node-id)
        NODE_ID="$(read_option_value "$1" "${2:-}")"
        shift 2
        ;;
      --api-key)
        API_KEY="$(read_option_value "$1" "${2:-}")"
        shift 2
        ;;
      --uninstall)
        UNINSTALL_MODE=true
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        print_error "Unknown option: $1"
        print_usage
        exit 1
        ;;
    esac
  done
}

validate_enrollment_args() {
  if [[ "${UNINSTALL_MODE}" == "true" ]]; then
    if [[ -n "${NODE_ID}" || -n "${API_KEY}" ]]; then
      print_error "--node-id/--api-key cannot be used with --uninstall."
      exit 1
    fi
    return
  fi

  if [[ -n "${NODE_ID}" && -z "${API_KEY}" ]]; then
    print_error "--api-key is required when --node-id is provided."
    exit 1
  fi

  if [[ -z "${NODE_ID}" && -n "${API_KEY}" ]]; then
    print_error "--node-id is required when --api-key is provided."
    exit 1
  fi
}

assert_prerequisites() {
  local required_cmds=(curl tar sha256sum)
  local cmd=""

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      print_error "Required command not found: ${cmd}"
      exit 1
    fi
  done
}

is_systemd_supported() {
  [[ -d "/run/systemd/system" ]] && command -v systemctl >/dev/null 2>&1
}

normalize_arch() {
  case "$1" in
    x86_64|amd64)
      print_line "amd64"
      ;;
    aarch64|arm64)
      print_line "arm64"
      ;;
    *)
      print_line "$1"
      ;;
  esac
}

detect_arch() {
  ARCH="$(normalize_arch "$(uname -m)")"
  case "${ARCH}" in
    amd64|arm64)
      ;;
    *)
      print_error "Unsupported architecture: ${ARCH}"
      exit 1
      ;;
  esac
}

resolve_package() {
  if [[ -n "${PACKAGE_URL}" ]]; then
    PACKAGE_NAME="$(basename "${PACKAGE_URL}")"
  else
    case "${ARCH}" in
      amd64)
        PACKAGE_NAME="${PACKAGE_NAME_AMD64}"
        ;;
      arm64)
        PACKAGE_NAME="${PACKAGE_NAME_ARM64}"
        ;;
    esac

    PACKAGE_URL="${PACKAGE_BASE_URL_DEFAULT}/${PACKAGE_NAME}"
  fi

  CHECKSUM_NAME="${PACKAGE_NAME}.sha256"
  CHECKSUM_URL="${PACKAGE_URL}.sha256"
}

print_welcome_banner() {
  print_line "----------------------------------------"
  print_line "Helguard Agent Installer (${INSTALLER_VERSION})"
  print_line "----------------------------------------"
}

print_plan() {
  print_line "Detected arch: ${ARCH}"
  print_line "Package:       ${PACKAGE_NAME}"
  print_line "Package URL:   ${PACKAGE_URL}"
  print_line "Checksum URL:  ${CHECKSUM_URL}"
  print_line "Work dir:      ${WORK_DIR}"
  if [[ -n "${NODE_ID}" ]]; then
    print_line "Node ID:       provided"
  else
    print_line "Node ID:       not provided"
  fi
  if [[ -n "${API_KEY}" ]]; then
    print_line "API key:       provided"
  else
    print_line "API key:       not provided"
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Mode:          dry-run"
  elif [[ "${UNINSTALL_MODE}" == "true" ]]; then
    print_line "Mode:          uninstall"
  else
    print_line "Mode:          install"
  fi
}

download_package_and_checksum() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Dry-run: would create work dir ${WORK_DIR}"
    print_line "Dry-run: would download ${PACKAGE_URL} -> ${WORK_DIR}/${PACKAGE_NAME}"
    print_line "Dry-run: would download ${CHECKSUM_URL} -> ${WORK_DIR}/${CHECKSUM_NAME}"
    return
  fi

  mkdir -p "${WORK_DIR}"
  curl -fsSL "${PACKAGE_URL}" -o "${WORK_DIR}/${PACKAGE_NAME}"
  curl -fsSL "${CHECKSUM_URL}" -o "${WORK_DIR}/${CHECKSUM_NAME}"
}

verify_package_checksum() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Dry-run: would verify checksum with sha256sum -c ${WORK_DIR}/${CHECKSUM_NAME}"
    return
  fi

  (
    cd "${WORK_DIR}"
    sha256sum -c "${CHECKSUM_NAME}"
  )
}

extract_package_archive() {
  local extract_dir="${WORK_DIR}/${EXTRACT_DIR_NAME}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Dry-run: would extract ${WORK_DIR}/${PACKAGE_NAME} to ${extract_dir}"
    return
  fi

  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  tar -xzf "${WORK_DIR}/${PACKAGE_NAME}" -C "${extract_dir}"
}

run_package_installer() {
  local package_root_dir="${WORK_DIR}/${EXTRACT_DIR_NAME}/${PACKAGE_ROOT_DIR_NAME}"
  local package_install_script="${package_root_dir}/install.sh"

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Dry-run: would execute ${package_install_script}"
    return
  fi

  if [[ ! -f "${package_install_script}" ]]; then
    print_error "Package install script not found: ${package_install_script}"
    exit 1
  fi

  print_line "Starting Helguard Agent package installation..."
  bash "${package_install_script}"
}

run_package_uninstaller() {
  local package_root_dir="${WORK_DIR}/${EXTRACT_DIR_NAME}/${PACKAGE_ROOT_DIR_NAME}"
  local package_uninstall_script="${package_root_dir}/uninstall.sh"

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Dry-run: would execute ${package_uninstall_script}"
    return
  fi

  if [[ ! -f "${package_uninstall_script}" ]]; then
    print_error "Package uninstall script not found: ${package_uninstall_script}"
    exit 1
  fi

  print_line "Starting Helguard Agent package uninstall..."
  bash "${package_uninstall_script}"
}

start_agent_after_enrollment() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Dry-run: would start agent after enrollment."
    return
  fi

  if is_systemd_supported; then
    print_line "Starting helguard-agent via systemd..."
    if systemctl start helguard-agent; then
      print_line "Agent started successfully with systemd."
      print_line "To start automatically on boot, run:"
      print_line "    sudo systemctl enable helguard-agent"
      return
    fi

    print_error "Failed to start helguard-agent with systemd."
    exit 1
  fi

  print_line "Systemd not detected. Starting agent via helguardctl..."
  if helguardctl start; then
    print_line "Agent started successfully."
    return
  fi

  print_error "Failed to start agent with helguardctl."
  exit 1
}

run_optional_enrollment() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ -n "${NODE_ID}" && -n "${API_KEY}" ]]; then
      print_line "Dry-run: would run helguardctl enroll --node-id <provided> --api-key <provided>"
    fi
    return
  fi

  if [[ -n "${NODE_ID}" && -n "${API_KEY}" ]]; then
    print_line "Enrolling node..."
    if helguardctl enroll --node-id "${NODE_ID}" --api-key "${API_KEY}"; then
      print_line "Enrollment successful."
      start_agent_after_enrollment
      return
    fi

    print_error "Enrollment failed."
    print_error "Please verify node credentials and network connectivity, then retry."
    exit 1
  fi

  print_line ""
  print_line "Helguard Agent installed successfully."
  print_line ""
  print_line "To enroll this node, run:"
  print_line ""
  print_line "    sudo helguardctl enroll --node-id <id> --api-key <key>"
  print_line ""
  print_line "Then start the service:"
  print_line ""
  print_line "    sudo systemctl enable --now helguard-agent"
}

print_ipv4_forwarding_note() {
  local ip_forward_file="/proc/sys/net/ipv4/ip_forward"
  local ip_forward_value=""

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_line "Dry-run: would check IPv4 forwarding state (${ip_forward_file})"
    return
  fi

  if [[ ! -r "${ip_forward_file}" ]]; then
    print_warn "Could not read ${ip_forward_file}; skipping IPv4 forwarding check."
    return
  fi

  ip_forward_value="$(tr -d '[:space:]' < "${ip_forward_file}")"
  if [[ "${ip_forward_value}" == "1" ]]; then
    print_line "IPv4 forwarding is enabled."
    return
  fi

  print_warn "IPv4 forwarding is disabled."
  print_line "If you plan to use advertised routes, enable it with:"
  print_line "  Temporary:"
  print_line "    sudo sysctl -w net.ipv4.ip_forward=1"
  print_line "  Persistent:"
  print_line "    echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-helguard-ipforward.conf"
  print_line "    sudo sysctl --system"
}

run_bootstrap() {
  print_line ""
  if [[ "${UNINSTALL_MODE}" == "true" ]]; then
    print_line "Bootstrap steps (uninstall mode):"
    print_line "  1. Download package archive and checksum"
    print_line "  2. Verify package checksum"
    print_line "  3. Extract archive into working directory"
    print_line "  4. Execute package uninstall.sh"
    print_line ""
  else
    print_line "Bootstrap steps:"
    print_line "  1. Download package archive and checksum"
    print_line "  2. Verify package checksum"
    print_line "  3. Extract archive into working directory"
    print_line "  4. Execute package install.sh"
    print_line "  5. Enroll node (optional)"
    print_line ""
  fi

  download_package_and_checksum
  verify_package_checksum
  extract_package_archive
  if [[ "${UNINSTALL_MODE}" == "true" ]]; then
    run_package_uninstaller
    print_line "Bootstrap uninstall completed."
  else
    run_package_installer
    run_optional_enrollment
    print_ipv4_forwarding_note
    print_line "Bootstrap installation completed."
  fi
}

main() {
  parse_args "$@"
  print_welcome_banner
  assert_root_access
  validate_enrollment_args
  assert_prerequisites
  detect_arch
  resolve_package
  print_plan
  run_bootstrap
}

main "$@"
