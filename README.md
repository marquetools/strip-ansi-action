# strip-ansi-action

> **Strip ANSI escape sequences and Unicode homograph threats from PR files and comments — fast, safe, and security-aware.**
> **Detects and warns about specific intercepted attacks**

A GitHub Action that runs [`distill-strip-ansi`](https://github.com/belt/distill-strip-ansi) against pull request files and GitHub comments, strips terminal control sequences, and fails the workflow if echoback attack vectors are detected.

It protects three surfaces in one action:

- **Changed files** — scans every file touched by a pull request.
- **PR comments** — scans (and optionally rewrites) PR discussion and review comments.
- **Issue comments** — scans (and optionally rewrites) comments on GitHub issues.

[![CI](https://github.com/marquetools/strip-ansi-action/actions/workflows/ci.yml/badge.svg)](https://github.com/marquetools/strip-ansi-action/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![License: Apache-2.0](https://img.shields.io/badge/Apache%202.0-brightgreen.svg)](https://opensource.org/licenses/Apache-2.0)

---

## Quick Start

**Scan changed files in a PR:**

```yaml
- name: Scan changed files for ANSI threats
  uses: marquetools/strip-ansi-action@v1
  with:
    files: ${{ steps.changed-files.outputs.all_changed_files }}
```

**Scan PR comments on every comment event:**

```yaml
- name: Scan PR comment for ANSI threats
  uses: marquetools/strip-ansi-action@v1
  with:
    clean-pr-comments: true
    on-threat: warn
```

**Scan issue comments on every comment event:**

```yaml
- name: Scan issue comment for ANSI threats
  uses: marquetools/strip-ansi-action@v1
  with:
    clean-issue-comments: true
    on-threat: warn
```

The action installs the `strip-ansi` binary, scans the requested surfaces, and fails the job (or warns/strips, depending on `on-threat`) when an echoback attack vector is found.

> **Want everything in one file?** See [Full Protection Workflow](#full-protection-workflow) below for a copy-paste workflow that covers all three surfaces and all relevant event types.

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `files` | No | _(empty)_ | Newline- or space-separated list of file paths to scan. Typically the output of [tj-actions/changed-files](https://github.com/tj-actions/changed-files). Leave empty when only scanning PR/Issue comments. |
| `on-threat` | No | `fail` | What to do when a threat is detected: `fail`, `strip`, or `warn`. See [Threat handling](#threat-handling) below. |
| `preset` | No | `sanitize` | ANSI filter preset. One of `dumb`, `color`, `sanitize`, `tmux`, `xterm`, `full`. |
| `unicode-map` | No | `@ascii-normalize` | Space-separated Unicode normalization sets to enable (e.g. `@ascii-normalize math-latin`). |
| `no-unicode-map` | No | _(empty)_ | Space-separated Unicode normalization sets to disable. |
| `version` | No | `0.5.2` | Version of `distill-strip-ansi` to install. |
| `clean-pr-comments` | No | `false` | When `true`, fetches and scans all PR comments (discussion + review) for threats. See [Cleaning PR & Issue comments](#cleaning-pr--issue-comments). |
| `clean-issue-comments` | No | `false` | When `true`, fetches and scans all issue comments for threats. See [Cleaning PR & Issue comments](#cleaning-pr--issue-comments). |
| `github-token` | No | `github.token` | Token used to read (and write, when `on-threat=strip`) comments. Defaults to the built-in `github.token`. |

## Outputs

| Output | Description |
|---|---|
| `results` | JSON array — `[{"file":"…","status":"clean\|stripped\|threat","output":"…"}]` |
| `threat-detected` | `"true"` if any file contained an echoback attack vector, `"false"` otherwise. |
| `files-with-threats` | Newline-separated list of file paths that contained threats. |
| `comment-results` | JSON array — `[{"id":"…","type":"pr_comment\|review_comment\|issue_comment","url":"…","status":"clean\|stripped\|threat","output":"…"}]` (populated when `clean-pr-comments` or `clean-issue-comments` is `true`) |
| `comment-threat-detected` | `"true"` if any comment contained an echoback attack vector, `"false"` otherwise. |
| `comments-with-threats` | Newline-separated list of comment HTML URLs that contained threats. |

---

## Usage Examples

### Scan all PR-changed files and fail on threat

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Get changed files
        id: changed-files
        uses: tj-actions/changed-files@v47

      - name: Strip ANSI threats
        uses: marquetools/strip-ansi-action@v1
        with:
          files: ${{ steps.changed-files.outputs.all_changed_files }}
          on-threat: fail
          preset: sanitize
```

### Strip threats silently and use the cleaned output downstream

```yaml
      - name: Strip ANSI threats
        id: strip
        uses: marquetools/strip-ansi-action@v1
        with:
          files: ${{ steps.changed-files.outputs.all_changed_files }}
          on-threat: strip
          preset: dumb

      - name: Check if threats were found
        run: echo "Threats present: ${{ steps.strip.outputs.threat-detected }}"
```

### Disable unicode normalization for generated/binary files

```yaml
      - name: Scan without unicode normalization
        uses: marquetools/strip-ansi-action@v1
        with:
          files: generated/output.log
          on-threat: warn
          no-unicode-map: '@ascii-normalize'
```

### Add Japanese canonicalization alongside the defaults

```yaml
      - name: Scan with extended unicode normalization
        uses: marquetools/strip-ansi-action@v1
        with:
          files: ${{ steps.changed-files.outputs.all_changed_files }}
          unicode-map: '@ascii-normalize @japanese'
```

---

## Full Protection Workflow

Copy this workflow into `.github/workflows/ansi-protection.yml` to enable full ANSI and Unicode threat scanning across all three surfaces — changed PR files, PR comments, and issue comments — in a single file.

```yaml
name: ANSI & Unicode Threat Protection

on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created, edited]
  pull_request_review_comment:
    types: [created, edited]
  pull_request_review:
    types: [submitted, edited]

permissions:
  contents: read
  issues: read
  pull-requests: read
  # Add 'issues: write' and/or 'pull-requests: write' here if you want the
  # action to rewrite comment bodies when on-threat is set to 'strip'.

jobs:
  scan:
    name: Scan for ANSI/Unicode threats
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      # Only needed for pull_request events; skipped automatically on comment events.
      - name: Get changed files
        id: changed-files
        if: github.event_name == 'pull_request'
        uses: tj-actions/changed-files@v47

      - name: Scan for ANSI/Unicode threats
        id: scan
        uses: marquetools/strip-ansi-action@v1
        with:
          # Scan changed files on pull_request events; empty on comment events (no-op).
          files: ${{ steps.changed-files.outputs.all_changed_files }}

          # Scan PR discussion + review comments on PR events.
          clean-pr-comments: >-
            ${{ github.event_name == 'pull_request' ||
                github.event_name == 'pull_request_review_comment' ||
                github.event_name == 'pull_request_review' }}

          # Scan issue comments on issue_comment events.
          clean-issue-comments: ${{ github.event_name == 'issue_comment' }}

          # Change to 'fail' to block on threat, or 'strip' to auto-clean comment bodies.
          on-threat: warn
          preset: sanitize

      - name: Report
        if: always()
        run: |
          echo "File threats:    ${{ steps.scan.outputs.threat-detected }}"
          echo "Comment threats: ${{ steps.scan.outputs.comment-threat-detected }}"
          if [ "${{ steps.scan.outputs.threat-detected }}" = "true" ]; then
            echo "Files with threats:"
            echo "${{ steps.scan.outputs.files-with-threats }}"
          fi
          if [ "${{ steps.scan.outputs.comment-threat-detected }}" = "true" ]; then
            echo "Comments with threats:"
            echo "${{ steps.scan.outputs.comments-with-threats }}"
          fi
```

**How event routing works:**

| Trigger event | Files scanned | PR comments scanned | Issue comments scanned |
|---|---|---|---|
| `pull_request` | ✅ Changed files | ✅ All PR comments | — |
| `pull_request_review_comment` | — | ✅ All PR comments | — |
| `pull_request_review` | — | ✅ All PR comments | — |
| `issue_comment` | — | — | ✅ All issue comments |

To auto-clean threats instead of warning, set `on-threat: strip` and upgrade the permissions to `pull-requests: write` and/or `issues: write`.

---

## Cleaning PR & Issue Comments

Set `clean-pr-comments: true` or `clean-issue-comments: true` to scan (and optionally strip threats from) GitHub PR and Issue comments.

### How it works

- **`clean-pr-comments: true`** — fetches every discussion comment and every review comment on the pull request that triggered the workflow and scans each body through `strip-ansi`.
- **`clean-issue-comments: true`** — fetches every comment on the issue that triggered the workflow and scans each body through `strip-ansi`.
- The same `on-threat` value controls what happens when a threat is found:
  - `fail` — emits `::error::` annotations and fails the job.
  - `warn` — emits `::warning::` annotations; the job continues.
  - `strip` — **rewrites the comment body** via the GitHub API to remove the threat sequences; the job continues.

### Required permissions

| Use case | Permission needed |
|---|---|
| Scan PR comments (read-only) | `pull-requests: read` |
| Strip threats from PR comments | `pull-requests: write` |
| Scan Issue comments (read-only) | `issues: read` |
| Strip threats from Issue comments | `issues: write` |

The default `github.token` already has these permissions when the workflow runs in the same repository.

### Example: scan PR comments and fail on threat

```yaml
jobs:
  scan-pr-comments:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: read
    steps:
      - uses: actions/checkout@v4

      - name: Scan PR comments for threats
        uses: marquetools/strip-ansi-action@v1
        with:
          clean-pr-comments: true
          on-threat: fail
```

### Example: strip threats from PR comments and files together

```yaml
jobs:
  strip-threats:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - name: Get changed files
        id: changed-files
        uses: tj-actions/changed-files@v47

      - name: Strip ANSI threats from files and PR comments
        id: strip
        uses: marquetools/strip-ansi-action@v1
        with:
          files: ${{ steps.changed-files.outputs.all_changed_files }}
          clean-pr-comments: true
          on-threat: strip

      - name: Report
        run: |
          echo "File threats: ${{ steps.strip.outputs.threat-detected }}"
          echo "Comment threats: ${{ steps.strip.outputs.comment-threat-detected }}"
```

### Example: scan Issue comments only

```yaml
on:
  issues:
    types: [opened, edited]

jobs:
  scan-issue:
    runs-on: ubuntu-latest
    permissions:
      issues: read
    steps:
      - uses: actions/checkout@v4

      - name: Scan issue comments for threats
        uses: marquetools/strip-ansi-action@v1
        with:
          clean-issue-comments: true
          on-threat: warn
```

### Per-comment event workflow (recommended for ongoing protection)

For continuous protection with minimal redundant work, trigger the action on **individual comment events** rather than scanning all comments in bulk every time. This fires only when a comment is created or edited, so it processes only the single comment that just changed.

See [`tests/comment-events.yml`](tests/comment-events.yml) for a ready-to-copy workflow, or use this minimal version:

```yaml
on:
  issue_comment:
    types: [created, edited]
  pull_request_review_comment:
    types: [created, edited]

permissions:
  contents: read
  issues: read
  pull-requests: read

jobs:
  scan-comment:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: marquetools/strip-ansi-action@v1
        with:
          clean-pr-comments: ${{ github.event_name == 'pull_request_review_comment' }}
          clean-issue-comments: ${{ github.event_name == 'issue_comment' }}
          on-threat: warn
```

---

## Threat Handling

The `on-threat` input controls what happens when the `strip-ansi` binary detects an **echoback attack vector** (exit code 77):

| Value | Behavior |
|---|---|
| `fail` _(default)_ | Emit `::error::` annotations for each offending file, then fail the step. |
| `strip` | Remove the threat sequences from the output; set `threat-detected=true`; continue. |
| `warn` | Emit `::warning::` annotations; set `threat-detected=true`; step succeeds. |

---

## ANSI Presets

| Preset | What survives |
|---|---|
| `dumb` | Nothing — strip everything. |
| `color` | SGR colors and styles only. |
| `sanitize` _(default)_ | Safe sequences (titles, hyperlinks). Echoback vectors are stripped. |
| `tmux` | All CSI and Fe sequences. |
| `xterm` | All OSC sequences. |
| `full` | Everything passes through unchanged. |

---

## Unicode Normalization

By default, the action enables the `@ascii-normalize` built-in set, which defends against **homograph attacks** — visually identical characters used to evade filters or deceive readers:

- **Fullwidth ASCII** (`Ａdmin` → `Admin`)
- **Math Bold Latin** (`𝐇𝐞𝐥𝐥𝐨` → `Hello`)
- **Enclosed Circled Letters** (`Ⓗⓔⓛⓛⓞ` → `Hello`)
- **Superscript/Subscript digits and operators**

Disable normalization selectively with `no-unicode-map`:

```yaml
no-unicode-map: 'fullwidth-ascii'   # disable only fullwidth
no-unicode-map: '@ascii-normalize'  # disable all defaults
```

Enable additional shipped mapping sets with `unicode-map`:

```yaml
unicode-map: '@japanese'   # add halfwidth-katakana, enclosed-cjk, cjk-compat
unicode-map: '@all'        # enable all shipped TOML files
```

---

## Security Notes

### What is an echoback attack vector?

Certain ANSI/VT terminal escape sequences cause the terminal emulator to **echo data back** into its own input stream. Attackers embed these sequences in CI log files, PR diffs, or user-generated content — when a developer views the output in a terminal, the sequence fires and can inject keystrokes, exfiltrate data, or cause commands to execute.

Classic examples:
- `ESC[6n` — Device Status Report (cursor position request): terminal responds with `ESC[row;colR` into stdin.
- `ESC[5n` — Device Status Report (device status): terminal echoes its status.

These sequences in a CI log file are **never legitimate**. The `sanitize` preset strips them automatically; `--check-threats` (always enabled by this action) exits with code 77 when any are found.

### Prompt Attacks

`distill-strip-ansi` protects against two kinds of prompt attacks -- one by default and one as configured by `strip-ansi-action`:

- Invisible ANSI. Uses ANSI hidden characters to send a complete prompt instruction to any LLM that reads it. The text looks completely innocuous otherwise, and prompts can be very long and detailed. `distill-strip-ansi` protects against these by default.
- Homograph attacks. Similarly use special unicode characters to evade filters and instruct llms to take an unwanted action. As discussed above, we turn the option on that blocks these by default.

### Supply-chain safety

- **Pin to a SHA** in security-sensitive workflows: `uses: marquetools/strip-ansi-action@<sha>`
- The action **never transmits file contents** to external services.
- The `distill-strip-ansi` binary is verified against its published SHA-256 checksum after download.
- Temporary files are written to `$RUNNER_TEMP`, not to the repository working directory.
- All shell inputs are quoted; `eval` is never used.

---

## How It Works

1. **Install** — Downloads the `strip-ansi` binary from the `belt/distill-strip-ansi` GitHub release (falls back to `cargo install`, then Homebrew). Cached per runner OS, arch, and version.
2. **Scan** — For each file, runs `strip-ansi --check-threats --preset=... < file > stripped`, adding `--on-threat=strip` only when `on-threat=strip`.
3. **Report** — Collects per-file status (`clean`, `stripped`, or `threat`) into a JSON array and writes all outputs to `$GITHUB_OUTPUT`.
4. **Gate** — If `on-threat=fail` and any threat was detected, the action emits error annotations and exits non-zero.

---

## License

You pick: [MIT](./LICENSE-MIT) or [Apache-2.0](./LICENSE-Apache-2.0) — © 2026 Knitli Inc.
