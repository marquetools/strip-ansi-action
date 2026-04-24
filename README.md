# strip-ansi-action

> **Strip ANSI escape sequences and Unicode homograph threats from PR files — fast, safe, and security-aware.**

A GitHub Action that runs [`distill-strip-ansi`](https://github.com/belt/distill-strip-ansi) against a list of files (e.g. files changed in a pull request), strips terminal control sequences, and fails the workflow if echoback attack vectors are detected.

[![CI](https://github.com/marquetools/strip-ansi-action/actions/workflows/ci.yml/badge.svg)](https://github.com/marquetools/strip-ansi-action/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)

---

## Quick Start

```yaml
- name: Scan changed files for ANSI threats
  uses: marquetools/strip-ansi-action@v1
  with:
    files: ${{ steps.changed-files.outputs.all_changed_files }}
```

That's it. The action installs the `strip-ansi` binary, scans every file, and fails the job if an echoback attack vector is found.

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `files` | **Yes** | — | Newline- or space-separated list of file paths to scan. Typically the output of [tj-actions/changed-files](https://github.com/tj-actions/changed-files). |
| `on-threat` | No | `fail` | What to do when a threat is detected: `fail`, `strip`, or `warn`. See [Threat handling](#threat-handling) below. |
| `preset` | No | `sanitize` | ANSI filter preset. One of `dumb`, `color`, `sanitize`, `tmux`, `xterm`, `full`. |
| `unicode-map` | No | `@ascii-normalize` | Space-separated Unicode normalization sets to enable (e.g. `@ascii-normalize math-latin`). |
| `no-unicode-map` | No | _(empty)_ | Space-separated Unicode normalization sets to disable. |
| `version` | No | `0.5.2` | Version of `distill-strip-ansi` to install. |

## Outputs

| Output | Description |
|---|---|
| `results` | JSON array — `[{"file":"…","status":"clean\|stripped\|threat","output":"…"}]` |
| `threat-detected` | `"true"` if any file contained an echoback attack vector, `"false"` otherwise. |
| `files-with-threats` | Newline-separated list of file paths that contained threats. |

---

## Usage Examples

### Scan all PR-changed files and fail on threat

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Get changed files
        id: changed-files
        uses: tj-actions/changed-files@v44

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

## Marketplace Publishing

> **Note:** To publish this action to the GitHub Actions Marketplace, the `action.yml` file must live at the **root** of a dedicated repository (e.g. `marquetools/strip-ansi-action`). Move the contents of the `strip-ansi-action/` directory to the root of that repository, then create a versioned release tag (e.g. `v1.0.0`). The Marketplace will pick it up automatically.

---

## License

[Mozilla Public License 2.0](LICENSE) — © 2026 Knitli Inc.
