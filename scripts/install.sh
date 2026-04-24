#!/usr/bin/env bash
# install.sh — Download and install the distill-strip-ansi binary.
#
# Environment variables consumed:
#   STRIP_ANSI_VERSION  — crates.io version to install (e.g. 0.5.2)
#
# The PATH entry for the installed binary is added by the calling action step
# (via $GITHUB_PATH), not by this script.
#
# Installation order (fastest to most reliable):
#   1. Pre-built binary download from the GitHub release
#   2. cargo install (requires Rust toolchain on the runner)
#   3. Homebrew on macOS (brew install belt/distill/distill-strip-ansi)
#
# The binary is verified against its published SHA-256 checksum when available.

set -euo pipefail

VERSION="${STRIP_ANSI_VERSION:-0.5.2}"
INSTALL_DIR="${HOME}/.local/bin"
BINARY="${INSTALL_DIR}/strip-ansi"
REPO="belt/distill-strip-ansi"
BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"

mkdir -p "${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[install] $*"; }

escape_workflow_command() {
  local message="$*"
  message="${message//'%'/'%25'}"
  message="${message//$'\r'/'%0D'}"
  message="${message//$'\n'/'%0A'}"
  printf '%s' "${message}"
}

warn() { echo "::warning::$(escape_workflow_command "$*")"; }
err()  { echo "::error::$(escape_workflow_command "$*")"; exit 1; }

have() { command -v "$1" &>/dev/null; }

# Detect OS / arch and map to Rust target triple components.
detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}" in
    Linux)              OS_NAME="unknown-linux-gnu" ;;
    Darwin)             OS_NAME="apple-darwin"      ;;
    MINGW*|MSYS*|CYGWIN*) OS_NAME="pc-windows-msvc" ;;
    *)
      warn "Unsupported OS: ${os}. Binary download skipped."
      OS_NAME=""
      ;;
  esac

  case "${arch}" in
    x86_64|amd64)  ARCH_NAME="x86_64"   ;;
    aarch64|arm64) ARCH_NAME="aarch64"  ;;
    *)
      warn "Unsupported architecture: ${arch}. Binary download skipped."
      ARCH_NAME=""
      ;;
  esac
}

# Download a URL to a local file using curl or wget.
download() {
  local url="$1" dest="$2"
  if have curl; then
    curl --fail --silent --show-error --location --output "${dest}" "${url}"
  elif have wget; then
    wget --quiet --output-document="${dest}" "${url}"
  else
    return 1
  fi
}

# Verify the SHA-256 checksum of a file.
verify_sha256() {
  local file="$1" expected="$2"
  local actual
  if have sha256sum; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  elif have shasum; then
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  else
    warn "No sha256sum or shasum found — skipping checksum verification."
    return 0
  fi
  if [ "${actual}" != "${expected}" ]; then
    echo "::error::Checksum mismatch for $(basename "${file}")"
    echo "::error::  expected: ${expected}"
    echo "::error::  actual:   ${actual}"
    return 1
  fi
  log "Checksum OK: ${actual}"
}

# ---------------------------------------------------------------------------
# Strategy 1: pre-built binary from GitHub Releases
# ---------------------------------------------------------------------------

download_binary() {
  [ -n "${OS_NAME}" ] && [ -n "${ARCH_NAME}" ] || return 1

  local target="${ARCH_NAME}-${OS_NAME}"
  local ext=""
  [ "${OS_NAME}" = "pc-windows-msvc" ] && ext=".exe"

  local asset_name="strip-ansi-${target}${ext}"
  local sha_name="${asset_name}.sha256"
  local tmp_bin
  tmp_bin="$(mktemp "${TMPDIR:-/tmp}/strip-ansi-bin.XXXXXX")"
  local tmp_sha
  tmp_sha="$(mktemp "${TMPDIR:-/tmp}/strip-ansi-sha.XXXXXX")"

  log "Attempting binary download: ${BASE_URL}/${asset_name}"

  if ! download "${BASE_URL}/${asset_name}" "${tmp_bin}"; then
    warn "Binary download failed for ${asset_name}."
    rm -f "${tmp_bin}" "${tmp_sha}"
    return 1
  fi

  # Download and verify checksum (best-effort; failure is non-fatal only if file is absent).
  if download "${BASE_URL}/${sha_name}" "${tmp_sha}" 2>/dev/null; then
    local expected
    expected="$(awk '{print $1}' "${tmp_sha}")"
    if ! verify_sha256 "${tmp_bin}" "${expected}"; then
      rm -f "${tmp_bin}" "${tmp_sha}"
      return 1
    fi
  else
    warn "No checksum file found at ${sha_name} — skipping verification."
  fi

  install -m 0755 "${tmp_bin}" "${BINARY}${ext}"
  rm -f "${tmp_bin}" "${tmp_sha}"

  # On Windows (Git Bash) the binary keeps the .exe suffix; create a shim without it.
  if [ "${ext}" = ".exe" ] && [ ! -f "${BINARY}" ]; then
    cp "${BINARY}.exe" "${BINARY}"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Strategy 2: cargo install
# ---------------------------------------------------------------------------

cargo_install() {
  have cargo || return 1
  log "Installing via cargo (this may take several minutes) ..."
  cargo install "distill-strip-ansi" \
    --version "${VERSION}" \
    --locked \
    --root "${HOME}/.local" 2>&1
}

# ---------------------------------------------------------------------------
# Strategy 3: Homebrew (macOS only)
# ---------------------------------------------------------------------------

brew_install() {
  have brew || return 1
  log "Installing via Homebrew ..."
  brew install belt/distill/distill-strip-ansi 2>&1

  local brew_bin
  brew_bin="$(brew --prefix)/bin/strip-ansi"
  if [ -f "${brew_bin}" ]; then
    ln -sf "${brew_bin}" "${BINARY}"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

detect_target

if download_binary; then
  log "Installed strip-ansi via pre-built binary."
elif cargo_install; then
  log "Installed strip-ansi via cargo."
elif brew_install; then
  log "Installed strip-ansi via Homebrew."
else
  err "All installation strategies failed for distill-strip-ansi@${VERSION}."
fi

log "--- Verification ---"
"${BINARY}" --version
log "Binary path: ${BINARY}"
