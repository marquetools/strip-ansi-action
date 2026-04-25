#!/usr/bin/env bash
# run.sh — Process a list of files through strip-ansi and emit GitHub Actions outputs.
#
# Environment variables consumed (all set from action.yml inputs):
#   INPUT_FILES     — newline- or space-separated file paths
#   INPUT_ON_THREAT — fail | strip | warn
#   INPUT_PRESET    — dumb | color | sanitize | tmux | xterm | full
#
# Outputs written to $GITHUB_OUTPUT:
#   results              — JSON array of {file, status, output}
#   threat-detected      — true | false
#   files-with-threats   — newline-separated file paths

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ON_THREAT="${INPUT_ON_THREAT:-fail}"
PRESET="${INPUT_PRESET:-sanitize}"

# Use RUNNER_TEMP when available (GitHub-hosted runners); fall back to /tmp.
WORK_DIR="${RUNNER_TEMP:-/tmp}/strip-ansi-$$"
mkdir -p "${WORK_DIR}"
# Ensure the temp directory is always removed on exit (normal or error).
trap 'rm -rf "${WORK_DIR}"' EXIT

# Maximum bytes of file content to include in the results JSON per file.
MAX_OUTPUT_BYTES=51200

# Maximum total bytes for the entire results JSON string (to stay within
# GITHUB_OUTPUT expression-length limits when scanning many files).
# When this cap is reached, further entries record status only (no output content).
MAX_RESULTS_BYTES=512000

# Detect a Python interpreter (python3 first, then python as a fallback).
if command -v python3 &>/dev/null; then
  PYTHON="python3"
elif command -v python &>/dev/null; then
  PYTHON="python"
else
  echo "::error::strip-ansi-action requires Python 3 (python3 or python) but none was found on PATH." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[strip-ansi] $*"; }

# Escape a string for use as a GitHub Actions workflow command property value
# (e.g. the value of "file=..." in ::error file=...::).
escape_annotation_property() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  s="${s//':'/'%3A'}"
  s="${s//','/'%2C'}"
  printf '%s' "${s}"
}

# Escape a string for use as a GitHub Actions workflow command message body.
escape_annotation_message() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  printf '%s' "${s}"
}

# Validate the on-threat input.
case "${ON_THREAT}" in
  fail|strip|warn) ;;
  *) echo "::error::Invalid on-threat value '$(escape_annotation_message "${ON_THREAT}")'. Must be fail, strip, or warn."; exit 1 ;;
esac

# Validate the preset input.
case "${PRESET}" in
  dumb|color|sanitize|tmux|xterm|full) ;;
  *) echo "::error::Invalid preset '$(escape_annotation_message "${PRESET}")'. Must be one of: dumb, color, sanitize, tmux, xterm, full."; exit 1 ;;
esac

# Build the flag array for strip-ansi.
# We always pass --check-threats so threats are detected regardless of on-threat value.
# When on-threat=strip we additionally pass --on-threat=strip so the binary strips them.
build_flags() {
  FLAGS=()
  FLAGS+=("--preset" "${PRESET}")
  FLAGS+=("--check-threats")

  if [ "${ON_THREAT}" = "strip" ]; then
    FLAGS+=("--on-threat=strip")
  fi
}

# JSON-encode a string using Python (detected at startup above).
json_string() {
  "${PYTHON}" -c "import sys, json; print(json.dumps(sys.argv[1]), end='')" "$1"
}

# Return the byte length of a string (not character count) so the results-size
# cap is accurate even when file content includes multi-byte UTF-8 sequences.
byte_len() {
  printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '
}

# Read a file and JSON-encode its contents, truncating at MAX_OUTPUT_BYTES.
json_file_content() {
  local path="$1"
  "${PYTHON}" - "${path}" "${MAX_OUTPUT_BYTES}" <<'PYEOF'
import sys, json
path, limit = sys.argv[1], int(sys.argv[2])
with open(path, 'rb') as f:
    data = f.read(limit)
text = data.decode('utf-8', errors='replace')
print(json.dumps(text), end='')
PYEOF
}

# ---------------------------------------------------------------------------
# Parse file list
#
# Primary delimiter: newline. This preserves file paths that contain spaces.
# For convenience, a single-line input with no newlines is treated as a
# space-separated list — but note that file paths with spaces are not
# supported in that fallback form. Use newline-separated inputs when paths
# may contain spaces (the standard output of a changed-files action).
# ---------------------------------------------------------------------------

_raw_input="${INPUT_FILES}"
# If the input contains no newlines, treat spaces as delimiters (simple one-liner form).
if [[ "${_raw_input}" != *$'\n'* ]]; then
  _raw_input="$(printf '%s' "${_raw_input}" | tr ' ' '\n')"
fi

# Build the FILES array using a while loop for Bash 3.x compatibility
# (mapfile/readarray requires Bash 4+, which is not the default on macOS).
FILES=()
while IFS= read -r _file; do
  if [ -n "${_file}" ] && [ -n "${_file// /}" ]; then
    FILES+=("${_file}")
  fi
done < <(printf '%s\n' "${_raw_input}" | sed '/^[[:space:]]*$/d')

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error::No files provided to the strip-ansi action (input 'files' is empty)."
  exit 1
fi

log "Scanning ${#FILES[@]} file(s) with preset=${PRESET}, on-threat=${ON_THREAT}"

# ---------------------------------------------------------------------------
# Per-file processing
# ---------------------------------------------------------------------------

build_flags

THREAT_DETECTED=false
FILES_WITH_THREATS=""
RESULTS_JSON="["
FIRST_ENTRY=true
RESULTS_CAPPED=false
FILE_INDEX=0

for file in "${FILES[@]}"; do
  FILE_INDEX=$(( FILE_INDEX + 1 ))
  if [ ! -f "${file}" ]; then
    ef="$(escape_annotation_property "${file}")"
    msg="$(escape_annotation_message "File not found, skipping: ${file}")"
    echo "::warning file=${ef}::${msg}"
    continue
  fi

  # Include a counter in the temp filename to avoid collisions when two input
  # paths share the same basename (e.g. src/foo.txt and tests/foo.txt).
  out_file="${WORK_DIR}/${FILE_INDEX}-$(basename "${file}").stripped"
  exit_code=0

  # Write stderr to a file under WORK_DIR (not /tmp) for portability and runner sandboxing.
  stderr_file="$(mktemp "${WORK_DIR}/strip-ansi-stderr.XXXXXX")"
  strip-ansi "${FLAGS[@]}" < "${file}" > "${out_file}" 2>"${stderr_file}" || exit_code=$?
  stderr_out="$(cat "${stderr_file}" 2>/dev/null || true)"
  rm -f "${stderr_file}"

  # Determine status from exit code.
  # Exit 77 means the binary detected echoback attack vectors.
  # Exit 0 means clean (or stripped, if --on-threat=strip was passed).
  status="clean"
  output_path="${out_file}"

  if [ "${exit_code}" -eq 77 ]; then
    THREAT_DETECTED=true
    FILES_WITH_THREATS+="${file}"$'\n'
    status="threat"

    if [ "${ON_THREAT}" = "warn" ]; then
      ef="$(escape_annotation_property "${file}")"
      msg="$(escape_annotation_message "Echoback attack vector detected in ${file}")"
      echo "::warning file=${ef}::${msg}"
    fi

    # Only expose output for threat findings when on-threat=strip explicitly
    # requests threat-stripped content. Warn/fail must not leak it downstream.
    [ "${ON_THREAT}" != "strip" ] && output_path=""

  elif [ "${exit_code}" -eq 0 ]; then
    # When on-threat=strip the binary exits 0 even when threats are present
    # (it strips them and emits one [strip-ansi:threat] line per threat to stderr).
    # Detect that case so we can set threat-detected=true and populate
    # files-with-threats correctly.
    if [ "${ON_THREAT}" = "strip" ] && printf '%s\n' "${stderr_out}" | grep -q '^\[strip-ansi:threat\]'; then
      THREAT_DETECTED=true
      FILES_WITH_THREATS+="${file}"$'\n'
      status="threat"
      # output_path already points to the stripped output; leave it set so the
      # threat-stripped content is included in the results JSON.
    elif ! diff -q "${file}" "${out_file}" &>/dev/null; then
      status="stripped"
    fi

  else
    # Unexpected exit code — surface the error and abort.
    if [ -n "${stderr_out}" ]; then
      echo "::error::strip-ansi stderr: $(escape_annotation_message "${stderr_out}")"
    fi
    ef="$(escape_annotation_property "${file}")"
    msg="$(escape_annotation_message "strip-ansi exited with unexpected code ${exit_code} for ${file}")"
    echo "::error file=${ef}::${msg}"
    exit "${exit_code}"
  fi

  log "${file}: ${status}"
  # Log stderr line-by-line so every line carries the [strip-ansi] prefix and
  # no line can accidentally start with '::' to inject a workflow command.
  if [ -n "${stderr_out}" ]; then
    while IFS= read -r _stderr_line; do
      log "  stderr: ${_stderr_line}"
    done <<< "${stderr_out}"
  fi

  # Build the output content JSON value.
  # Once the global results cap is reached, omit output content to prevent
  # GITHUB_OUTPUT from growing unboundedly when many files are scanned.
  if [ "${RESULTS_CAPPED}" = "false" ] && [ -n "${output_path}" ] && [ -f "${output_path}" ]; then
    out_json="$(json_file_content "${output_path}")"
  else
    out_json='""'
  fi

  file_json="$(json_string "${file}")"
  entry="{\"file\":${file_json},\"status\":\"${status}\",\"output\":${out_json}}"

  # Compute the bytes this entry would add (including separator comma if needed).
  entry_sep_bytes=1
  [ "${FIRST_ENTRY}" = "true" ] && entry_sep_bytes=0
  projected_bytes=$(( $(byte_len "${RESULTS_JSON}") + $(byte_len "${entry}") + entry_sep_bytes ))

  # If this entry would push the results JSON over the global cap, switch to
  # content-free entries for the remainder of the file list.
  # Use byte_len (not ${#...}) so multi-byte UTF-8 sequences are counted correctly.
  if [ "${RESULTS_CAPPED}" = "false" ] && [ "${projected_bytes}" -gt ${MAX_RESULTS_BYTES} ]; then
    RESULTS_CAPPED=true
    log "Global results JSON cap (${MAX_RESULTS_BYTES} bytes) reached; omitting output content for remaining files."
    out_json='""'
    entry="{\"file\":${file_json},\"status\":\"${status}\",\"output\":${out_json}}"
    projected_bytes=$(( $(byte_len "${RESULTS_JSON}") + $(byte_len "${entry}") + entry_sep_bytes ))
  fi

  # If even the content-free entry would exceed the cap, stop appending so
  # the emitted results output always stays within the configured limit.
  if [ "${projected_bytes}" -gt ${MAX_RESULTS_BYTES} ]; then
    log "Global results JSON cap (${MAX_RESULTS_BYTES} bytes) prevents adding further entries; truncating results list."
    break
  fi

  if [ "${FIRST_ENTRY}" = "true" ]; then
    FIRST_ENTRY=false
  else
    RESULTS_JSON+=","
  fi
  RESULTS_JSON+="${entry}"
done

RESULTS_JSON+="]"

# ---------------------------------------------------------------------------
# Emit outputs to GITHUB_OUTPUT
# ---------------------------------------------------------------------------

# Generate a unique heredoc delimiter that cannot collide with any file path.
FWT_DELIM="_STRIP_ANSI_EOF_${$}_${RANDOM}${RANDOM}"
while printf '%s\n' "${FILES_WITH_THREATS}" | grep -Fqx "${FWT_DELIM}"; do
  FWT_DELIM="_STRIP_ANSI_EOF_${$}_${RANDOM}${RANDOM}"
done

{
  echo "results=${RESULTS_JSON}"
  echo "threat-detected=${THREAT_DETECTED}"
  printf 'files-with-threats<<%s\n%s%s\n' "${FWT_DELIM}" "${FILES_WITH_THREATS}" "${FWT_DELIM}"
} >> "${GITHUB_OUTPUT}"

log "Done. threat-detected=${THREAT_DETECTED}"
