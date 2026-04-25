#!/usr/bin/env bash
# clean-comments.sh — Fetch and optionally strip threats from PR/Issue comments.
#
# Environment variables consumed (all set from action.yml inputs):
#   INPUT_GITHUB_TOKEN          — GitHub API token (falls back to github.token)
#   INPUT_CLEAN_PR_COMMENTS     — true | false
#   INPUT_CLEAN_ISSUE_COMMENTS  — true | false
#   INPUT_ON_THREAT             — fail | strip | warn
#   INPUT_PRESET                — dumb | color | sanitize | tmux | xterm | full
#   INPUT_UNICODE_MAP           — space-separated --unicode-map tokens
#   INPUT_NO_UNICODE_MAP        — space-separated --no-unicode-map tokens
#   GITHUB_REPOSITORY           — owner/repo
#   GITHUB_EVENT_PATH           — path to the event JSON file
#   GITHUB_API_URL              — base URL for the GitHub API
#
# Outputs written to $GITHUB_OUTPUT:
#   comment-results             — JSON array of {id, type, url, status, output}
#   comment-threat-detected     — true | false
#   comments-with-threats       — newline-separated list of comment URLs with threats

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ON_THREAT="${INPUT_ON_THREAT:-fail}"
PRESET="${INPUT_PRESET:-sanitize}"
UNICODE_MAP="${INPUT_UNICODE_MAP:-@ascii-normalize}"
NO_UNICODE_MAP="${INPUT_NO_UNICODE_MAP:-}"
GITHUB_TOKEN="${INPUT_GITHUB_TOKEN:-}"
CLEAN_PR_COMMENTS="${INPUT_CLEAN_PR_COMMENTS:-false}"
CLEAN_ISSUE_COMMENTS="${INPUT_CLEAN_ISSUE_COMMENTS:-false}"

REPO="${GITHUB_REPOSITORY:-}"
API_URL="${GITHUB_API_URL:-https://api.github.com}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"

# Use RUNNER_TEMP when available; fall back to /tmp.
WORK_DIR="${RUNNER_TEMP:-/tmp}/strip-ansi-comments-$$"
mkdir -p "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Maximum bytes of comment content to include in the results JSON per comment.
MAX_OUTPUT_BYTES=51200

# Maximum total bytes for the entire comment-results JSON string.
MAX_RESULTS_BYTES=512000

# Detect a Python 3 interpreter.
if command -v python3 &>/dev/null; then
  PYTHON="python3"
elif command -v python &>/dev/null && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
  PYTHON="python"
else
  echo "::error::strip-ansi-action requires Python 3 (python3 or python) but none was found on PATH." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[strip-ansi-comments] $*"; }

escape_annotation_property() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  s="${s//':'/'%3A'}"
  s="${s//','/'%2C'}"
  printf '%s' "${s}"
}

escape_annotation_message() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  printf '%s' "${s}"
}

json_string() {
  "${PYTHON}" -c "import sys, json; print(json.dumps(sys.argv[1]), end='')" "$1"
}

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

if [ -z "${GITHUB_TOKEN}" ]; then
  echo "::error::github-token is required when clean-pr-comments or clean-issue-comments is enabled." >&2
  exit 1
fi

if [ -z "${REPO}" ]; then
  echo "::error::GITHUB_REPOSITORY is not set." >&2
  exit 1
fi

# Build the flag array for strip-ansi (same logic as run.sh).
build_flags() {
  FLAGS=()
  FLAGS+=("--preset" "${PRESET}")
  FLAGS+=("--check-threats")

  if [ "${ON_THREAT}" = "strip" ]; then
    FLAGS+=("--on-threat=strip")
  fi

  if [ -n "${UNICODE_MAP}" ]; then
    set -f
    for token in ${UNICODE_MAP}; do
      FLAGS+=("--unicode-map" "${token}")
    done
    set +f
  fi

  if [ -n "${NO_UNICODE_MAP}" ]; then
    set -f
    for token in ${NO_UNICODE_MAP}; do
      FLAGS+=("--no-unicode-map" "${token}")
    done
    set +f
  fi
}

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------

# Fetch all pages of comments from an API endpoint into a single JSON array file.
fetch_all_comments() {
  local endpoint="$1" out_file="$2"
  local page=1 per_page=100
  local tmp_page
  tmp_page="${WORK_DIR}/fetch-page-$$.json"

  echo "[]" > "${out_file}"

  while true; do
    if ! curl --fail --silent --show-error --location \
        --header "Authorization: Bearer ${GITHUB_TOKEN}" \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "${tmp_page}" \
        "${endpoint}?per_page=${per_page}&page=${page}"; then
      echo "::error::Failed to fetch page ${page} of comments from ${endpoint}. Aborting to avoid an incomplete scan." >&2
      exit 1
    fi

    local count
    count="$("${PYTHON}" -c "import sys,json; d=json.load(open(sys.argv[1])); print(len(d))" "${tmp_page}" 2>/dev/null || echo 0)"
    if [ "${count}" -eq 0 ]; then break; fi

    # Merge this page into the combined file.
    "${PYTHON}" - "${out_file}" "${tmp_page}" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    combined = json.load(f)
with open(sys.argv[2]) as f:
    page_data = json.load(f)
combined.extend(page_data)
with open(sys.argv[1], 'w') as f:
    json.dump(combined, f)
PYEOF

    if [ "${count}" -lt "${per_page}" ]; then break; fi
    page=$(( page + 1 ))
  done

  rm -f "${tmp_page}"
}

# Update a comment body via the GitHub API (PATCH).
update_comment() {
  local update_url="$1" body_file="$2"
  local json_body
  json_body="$("${PYTHON}" - "${body_file}" <<'PYEOF'
import sys, json
with open(sys.argv[1], 'r', errors='replace') as f:
    body = f.read()
print(json.dumps({"body": body}))
PYEOF
)"
  curl --fail --silent --show-error --location \
    --request PATCH \
    --header "Authorization: Bearer ${GITHUB_TOKEN}" \
    --header "Accept: application/vnd.github+json" \
    --header "Content-Type: application/json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --data "${json_body}" \
    "${update_url}" > /dev/null
}

# ---------------------------------------------------------------------------
# Event context helpers
# ---------------------------------------------------------------------------

# Print the PR number if the event contains a pull request.
get_pr_number() {
  [ -f "${EVENT_PATH}" ] || return 0
  "${PYTHON}" - "${EVENT_PATH}" <<'PYEOF' 2>/dev/null || true
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
# pull_request events and issue_comment events on PRs both expose a PR number.
pr = d.get('pull_request') or {}
issue = d.get('issue') or {}
num = pr.get('number') or (issue.get('number') if issue.get('pull_request') else None)
if num:
    print(num)
PYEOF
}

# Print the issue number only for real issues (not PRs).
get_issue_number() {
  [ -f "${EVENT_PATH}" ] || return 0
  "${PYTHON}" - "${EVENT_PATH}" <<'PYEOF' 2>/dev/null || true
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
issue = d.get('issue') or {}
# Only emit a number when the event issue is a real issue, not a PR.
if issue.get('number') and not issue.get('pull_request'):
    print(issue['number'])
PYEOF
}

# ---------------------------------------------------------------------------
# Comment processing
# ---------------------------------------------------------------------------

# Process all comments in a JSON array file through strip-ansi.
#   json_file    — path to JSON array of GitHub comment objects
#   comment_type — pr_comment | review_comment | issue_comment
#   update_base  — base URL for PATCH updates (appended with /{comment_id})
process_comments_file() {
  local json_file="$1" comment_type="$2" update_base="$3"

  local count
  count="$("${PYTHON}" -c "import sys,json; print(len(json.load(open(sys.argv[1]))))" "${json_file}")"
  log "Processing ${count} ${comment_type}(s)..."

  # Emit one line per comment: id<TAB>html_url
  # A single Python pass writes all comment bodies to individual files and
  # emits the id/html_url pairs, so each comment is visited exactly once.
  local id html_url
  while IFS=$'\t' read -r id html_url; do
    [ -z "${id}" ] && continue

    local body_file="${WORK_DIR}/comment-body-${id}.txt"

    # Skip completely empty comment bodies.
    if [ ! -s "${body_file}" ]; then
      log "${comment_type} ${id}: clean (empty body)"
      rm -f "${body_file}"

      local entry
      entry="$(build_comment_entry "${id}" "${comment_type}" "${html_url}" "clean" '""')"
      # output is already '""' (empty), so full_entry == cap_entry here.
      _append_entry "${entry}" "${entry}"
      continue
    fi

    local out_file="${WORK_DIR}/comment-out-${id}.stripped"
    local exit_code=0
    local stderr_file
    stderr_file="$(mktemp "${WORK_DIR}/strip-ansi-stderr.XXXXXX")"
    strip-ansi "${FLAGS[@]}" < "${body_file}" > "${out_file}" 2>"${stderr_file}" || exit_code=$?
    local stderr_out
    stderr_out="$(cat "${stderr_file}" 2>/dev/null || true)"
    rm -f "${stderr_file}"

    local status="clean"
    local out_json='""'

    if [ "${exit_code}" -eq 77 ]; then
      # Echoback attack vector detected.
      status="threat"
      THREAT_DETECTED=true
      COMMENTS_WITH_THREATS+="${html_url}"$'\n'

      if [ "${ON_THREAT}" = "warn" ]; then
        msg="$(escape_annotation_message "Echoback attack vector detected in ${comment_type} (${html_url})")"
        echo "::warning::${msg}"
      fi

      if [ "${ON_THREAT}" = "strip" ]; then
        if update_comment "${update_base}/${id}" "${out_file}"; then
          log "Updated ${comment_type} ${id} to remove threats."
        else
          echo "::warning::Failed to update ${comment_type} ${id} via API." >&2
        fi
        out_json="$(json_file_content "${out_file}")"
      fi

    elif [ "${exit_code}" -eq 0 ]; then
      if ! diff -q "${body_file}" "${out_file}" &>/dev/null; then
        status="stripped"
        if [ "${ON_THREAT}" = "strip" ]; then
          if update_comment "${update_base}/${id}" "${out_file}"; then
            log "Updated ${comment_type} ${id} to remove ANSI sequences."
          else
            echo "::warning::Failed to update ${comment_type} ${id} via API." >&2
          fi
        fi
      fi
      out_json="$(json_file_content "${out_file}")"

    else
      # Unexpected exit code — surface the error and abort.
      if [ -n "${stderr_out}" ]; then
        echo "::error::strip-ansi stderr: $(escape_annotation_message "${stderr_out}")"
      fi
      ef="$(escape_annotation_property "${html_url}")"
      msg="$(escape_annotation_message "strip-ansi exited with unexpected code ${exit_code} for ${comment_type} ${id}")"
      echo "::error file=${ef}::${msg}"
      rm -f "${body_file}" "${out_file}"
      exit "${exit_code}"
    fi

    log "${comment_type} ${id}: ${status}"
    if [ -n "${stderr_out}" ]; then
      while IFS= read -r _stderr_line; do
        log "  stderr: ${_stderr_line}"
      done <<< "${stderr_out}"
    fi

    rm -f "${body_file}" "${out_file}"

    local entry cap_entry
    entry="$(build_comment_entry "${id}" "${comment_type}" "${html_url}" "${status}" "${out_json}")"
    cap_entry="$(build_comment_entry "${id}" "${comment_type}" "${html_url}" "${status}" '""')"
    _append_entry "${entry}" "${cap_entry}"

  done < <("${PYTHON}" - "${json_file}" "${WORK_DIR}" <<'PYEOF'
import sys, json, os
with open(sys.argv[1]) as f:
    data = json.load(f)
work_dir = sys.argv[2]
for c in data:
    cid = str(c['id'])
    body = c.get('body') or ''
    with open(os.path.join(work_dir, 'comment-body-' + cid + '.txt'), 'w', encoding='utf-8') as bf:
        bf.write(body)
    print(cid + '\t' + (c.get('html_url') or ''))
PYEOF
)
}

# Build a JSON result entry for a single comment.
# Args: id, comment_type, html_url, status, out_json
build_comment_entry() {
  local id="$1" comment_type="$2" html_url="$3" status="$4" out_json="$5"
  echo "{\"id\":$(json_string "${id}"),\"type\":\"${comment_type}\",\"url\":$(json_string "${html_url}"),\"status\":\"${status}\",\"output\":${out_json}}"
}

# Append a JSON entry to COMMENT_RESULTS_JSON, honouring the global size cap.
# Args: full_entry  cap_entry (same entry but with output set to "")
# Once the cap is reached, metadata-only (cap) entries are still appended until
# even a content-free entry would exceed the limit, matching run.sh behaviour.
_append_entry() {
  local entry="$1" cap_entry="$2"

  local sep_bytes=1
  [ "${FIRST_ENTRY}" = "true" ] && sep_bytes=0

  # If not yet capped, try the full entry first.
  if [ "${RESULTS_CAPPED}" = "false" ]; then
    local projected
    projected=$(( $(byte_len "${COMMENT_RESULTS_JSON}") + $(byte_len "${entry}") + sep_bytes ))
    if [ "${projected}" -le "${MAX_RESULTS_BYTES}" ]; then
      if [ "${FIRST_ENTRY}" = "true" ]; then FIRST_ENTRY=false; else COMMENT_RESULTS_JSON+=","; fi
      COMMENT_RESULTS_JSON+="${entry}"
      return
    fi
    # Full entry doesn't fit; switch to content-free entries for the remainder.
    RESULTS_CAPPED=true
    log "Global comment-results JSON cap (${MAX_RESULTS_BYTES} bytes) reached; omitting output content for remaining comments."
    entry="${cap_entry}"
  else
    entry="${cap_entry}"
  fi

  # Try the content-free (cap) entry.
  local projected
  projected=$(( $(byte_len "${COMMENT_RESULTS_JSON}") + $(byte_len "${entry}") + sep_bytes ))
  if [ "${projected}" -gt "${MAX_RESULTS_BYTES}" ]; then
    log "Global comment-results JSON cap (${MAX_RESULTS_BYTES} bytes) prevents adding further entries; truncating results list."
    return
  fi

  if [ "${FIRST_ENTRY}" = "true" ]; then FIRST_ENTRY=false; else COMMENT_RESULTS_JSON+=","; fi
  COMMENT_RESULTS_JSON+="${entry}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

build_flags

THREAT_DETECTED=false
COMMENTS_WITH_THREATS=""
COMMENT_RESULTS_JSON="["
FIRST_ENTRY=true
RESULTS_CAPPED=false

# --- PR comments ---
if [ "${CLEAN_PR_COMMENTS}" = "true" ]; then
  PR_NUMBER="$(get_pr_number)"
  if [ -z "${PR_NUMBER}" ]; then
    echo "::warning::clean-pr-comments=true but no pull request found in the event context. Skipping PR comment scan."
  else
    log "Scanning PR #${PR_NUMBER} comments in ${REPO}..."

    # PR discussion comments (issues endpoint)
    pr_comments_file="${WORK_DIR}/pr-comments.json"
    fetch_all_comments "${API_URL}/repos/${REPO}/issues/${PR_NUMBER}/comments" "${pr_comments_file}"
    process_comments_file "${pr_comments_file}" "pr_comment" "${API_URL}/repos/${REPO}/issues/comments"
    rm -f "${pr_comments_file}"

    # PR review comments (pulls endpoint)
    review_comments_file="${WORK_DIR}/pr-review-comments.json"
    fetch_all_comments "${API_URL}/repos/${REPO}/pulls/${PR_NUMBER}/comments" "${review_comments_file}"
    process_comments_file "${review_comments_file}" "review_comment" "${API_URL}/repos/${REPO}/pulls/comments"
    rm -f "${review_comments_file}"
  fi
fi

# --- Issue comments ---
if [ "${CLEAN_ISSUE_COMMENTS}" = "true" ]; then
  ISSUE_NUMBER="$(get_issue_number)"
  if [ -z "${ISSUE_NUMBER}" ]; then
    echo "::warning::clean-issue-comments=true but no issue found in the event context. Skipping issue comment scan."
  else
    log "Scanning issue #${ISSUE_NUMBER} comments in ${REPO}..."

    issue_comments_file="${WORK_DIR}/issue-comments.json"
    fetch_all_comments "${API_URL}/repos/${REPO}/issues/${ISSUE_NUMBER}/comments" "${issue_comments_file}"
    process_comments_file "${issue_comments_file}" "issue_comment" "${API_URL}/repos/${REPO}/issues/comments"
    rm -f "${issue_comments_file}"
  fi
fi

COMMENT_RESULTS_JSON+="]"

# ---------------------------------------------------------------------------
# Emit outputs to GITHUB_OUTPUT
# ---------------------------------------------------------------------------

CWT_DELIM="_STRIP_ANSI_COMMENTS_EOF_${$}_${GITHUB_RUN_ID:-0}_${RANDOM}${RANDOM}"
while printf '%s\n' "${COMMENTS_WITH_THREATS}" | grep -Fqx "${CWT_DELIM}"; do
  CWT_DELIM="_STRIP_ANSI_COMMENTS_EOF_${$}_${GITHUB_RUN_ID:-0}_${RANDOM}${RANDOM}"
done

{
  echo "comment-results=${COMMENT_RESULTS_JSON}"
  echo "comment-threat-detected=${THREAT_DETECTED}"
  printf 'comments-with-threats<<%s\n%s%s\n' "${CWT_DELIM}" "${COMMENTS_WITH_THREATS}" "${CWT_DELIM}"
} >> "${GITHUB_OUTPUT}"

log "Done. comment-threat-detected=${THREAT_DETECTED}"
