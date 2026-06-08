#!/usr/bin/env bash
#
# check_secrets.sh — a lightweight, offline secret & privacy scan.
#
# This is a guardrail, not a vault scanner: it catches the *obvious* mistakes
# (a committed keystore, a pasted private key, an API token, a diagnostics
# snapshot with a real server URL) before they reach a PR or a release. It is
# deliberately:
#
#   * Offline — no network calls, no downloads, no external services.
#   * Dependency-free — pure bash + git/grep, nothing to install.
#   * Fast — it scans only tracked files (git ls-files), skipping binaries.
#   * Local-twin — the CI "secret-scan" job runs exactly this script, so a
#     contributor sees the same result with `./scripts/check_secrets.sh`.
#
# It checks three things:
#
#   1. Forbidden files — a tracked file whose name marks it as a secret
#      (.env, *.keystore/*.jks, *.pem/*.key/*.p12, an SSH private key,
#      key.properties, a Play service-account JSON, …). `*.example` /
#      `*.sample` / `*.template` placeholders are allowed.
#   2. Secret content — high-signal secret *formats* anywhere in tracked text
#      (a PEM "BEGIN … PRIVATE KEY" block, a GitHub/Slack/AWS/Google token).
#      The patterns are specific on purpose so they do NOT flag the redaction
#      test inputs (e.g. `?api_key=secret`, `user:pass@…`) the diagnostics
#      suite deliberately carries.
#   3. Diagnostics privacy — any committed diagnostics *fixture/snapshot* must
#      not carry a real private URL, credential, token, or home path. Reserved
#      example hosts (example.com, localhost, RFC1918, TEST-NET) are allowed.
#
# Exit status: 0 if clean, 1 if anything was found (each finding is printed
# with its file:line so it is easy to fix or, if it is a deliberate sample,
# move under an *.example name or a fixture allowlist host).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# This script intentionally contains the secret *patterns* as literals, so it
# would otherwise flag itself in the content scan. Exclude it (and nothing
# else) from the surfaces below.
SELF="scripts/check_secrets.sh"

RED=""; YELLOW=""; BOLD=""; RESET=""
if [ -t 1 ]; then
  RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
fi

findings=0
note()  { printf '%s\n' "$*"; }
fail()  { findings=$((findings + 1)); printf '%s%s%s\n' "$RED" "$*" "$RESET"; }
header(){ printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }

# Tracked files only — deterministic and fast. NUL-separated for odd names.
mapfile -d '' -t TRACKED < <(git ls-files -z 2>/dev/null)
if [ "${#TRACKED[@]}" -eq 0 ]; then
  note "WARNING: no tracked files found (not a git checkout?). Nothing to scan."
  exit 0
fi

# A path is an allowed placeholder if it ends in a clearly-non-secret suffix
# or carries an example/sample/template marker in its name.
is_placeholder() {
  case "$1" in
    *.example|*.sample|*.template|*.dist|*.tmpl) return 0 ;;
    *example*|*sample*|*template*) return 0 ;;
    *) return 1 ;;
  esac
}

# ----------------------------------------------------------------------------
# 1. Forbidden files (by name). These should never be committed at all.
# ----------------------------------------------------------------------------
header "Checking for committed secret files"
secret_file_hits=0
for f in "${TRACKED[@]}"; do
  base="${f##*/}"
  case "$base" in
    .env|.env.*|\
    *.keystore|*.jks|*.p12|*.pfx|*.pem|*.key|*.der|*.mobileprovision|\
    id_rsa|id_dsa|id_ecdsa|id_ed25519|*.ppk|\
    key.properties|\
    secring.*|*.gpg|\
    service-account*.json|play-console*.json|google-services-account*.json)
      if is_placeholder "$f"; then
        continue
      fi
      fail "  secret file committed: $f"
      secret_file_hits=$((secret_file_hits + 1))
      ;;
  esac
done
[ "$secret_file_hits" -eq 0 ] && note "  none"

# ----------------------------------------------------------------------------
# 2. Secret content (high-signal formats). git grep skips binaries with -I.
# ----------------------------------------------------------------------------
header "Scanning tracked text for secret material"

# One alternation of *specific* secret shapes. Specificity is the whole point:
# a generic "password" keyword would drown in the diagnostics code/tests that
# legitimately mention tokens/passwords while asserting they are redacted.
SECRET_RE='-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----'      # PEM/OpenSSH private keys
SECRET_RE="$SECRET_RE|gh[opsu]_[0-9A-Za-z]{36}"            # GitHub tokens
SECRET_RE="$SECRET_RE|github_pat_[0-9A-Za-z_]{40,}"        # GitHub fine-grained PAT
SECRET_RE="$SECRET_RE|xox[baprs]-[0-9A-Za-z-]{10,}"        # Slack tokens
SECRET_RE="$SECRET_RE|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}"  # AWS access key id
SECRET_RE="$SECRET_RE|AIza[0-9A-Za-z_-]{35}"              # Google API key
SECRET_RE="$SECRET_RE|-----BEGIN PGP PRIVATE KEY BLOCK-----"

if git grep -nIE -e "$SECRET_RE" -- . ":(exclude)$SELF" >/tmp/linthra_secret_hits 2>/dev/null; then
  while IFS= read -r line; do
    fail "  $line"
  done < /tmp/linthra_secret_hits
  note ""
  note "  ${YELLOW}If a hit is a deliberate placeholder, rename the file to *.example${RESET}"
  note "  ${YELLOW}or replace the value with a clearly-fake token.${RESET}"
else
  note "  none"
fi
rm -f /tmp/linthra_secret_hits

# ----------------------------------------------------------------------------
# 3. Diagnostics privacy — only committed fixture/snapshot artifacts, never the
#    unit-test sources (which carry redaction inputs on purpose). The runtime
#    redaction itself is unit-tested in test/core/diagnostics/.
# ----------------------------------------------------------------------------
header "Scanning diagnostics fixtures/snapshots for private data"

FIXTURES=()
for f in "${TRACKED[@]}"; do
  case "$f" in
    *.dart) continue ;;  # source/tests carry redaction inputs deliberately
    */fixtures/*|*/snapshots/*|*/__snapshots__/*|*/goldens/*|*.golden|\
    *diagnostics*.txt|*diagnostics*.log|*diagnostics*.json|\
    *bug-report*.txt|*bug_report*.txt|*bug-report*.md)
      FIXTURES+=("$f") ;;
  esac
done

if [ "${#FIXTURES[@]}" -eq 0 ]; then
  note "  (no diagnostics fixture/snapshot files tracked; nothing to scan)"
else
  # Obvious private data: credentialed URLs, real home paths, password=/token=
  # assignments, plus the same high-signal secret formats from step 2.
  PRIV_RE='://[^/[:space:]@]+:[^/[:space:]@]+@[^/[:space:]]+'           # user:pass@host
  PRIV_RE="$PRIV_RE|/home/[A-Za-z0-9._-]+/|/Users/[A-Za-z0-9._-]+/"     # unix home dirs
  PRIV_RE="$PRIV_RE|[A-Za-z]:\\\\Users\\\\[A-Za-z0-9._-]+"             # windows home dirs
  PRIV_RE="$PRIV_RE|(password|passwd|pwd|secret|token|api[_-]?key)[\"'\'']?[[:space:]]*[:=][[:space:]]*[\"'\'']?[A-Za-z0-9._/+-]{6,}"
  PRIV_RE="$PRIV_RE|$SECRET_RE"

  # Reserved/example hosts, RFC1918, TEST-NET, and obvious placeholders are
  # allowed so a documentation-style fixture does not trip the scan.
  ALLOW_RE='example\.(com|org|net)|localhost|127\.0\.0\.1|::1|0\.0\.0\.0'
  ALLOW_RE="$ALLOW_RE|10\.[0-9]|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\."
  ALLOW_RE="$ALLOW_RE|192\.0\.2\.|198\.51\.100\.|203\.0\.113\."           # TEST-NET-1/2/3
  ALLOW_RE="$ALLOW_RE|redacted|placeholder|example|REPLACE|CHANGEME|xxxx|<[A-Za-z]"
  ALLOW_RE="$ALLOW_RE|your|username|johndoe|janedoe"                       # common placeholder users

  priv_hits=0
  for f in "${FIXTURES[@]}"; do
    while IFS= read -r line; do
      printf '%s\n' "$line" | grep -qE "$ALLOW_RE" && continue
      fail "  $f: $line"
      priv_hits=$((priv_hits + 1))
    done < <(grep -nIE -- "$PRIV_RE" "$f" 2>/dev/null)
  done
  [ "$priv_hits" -eq 0 ] && note "  none (scanned ${#FIXTURES[@]} fixture/snapshot file(s))"
fi

# ----------------------------------------------------------------------------
header "Summary"
if [ "$findings" -eq 0 ]; then
  note "  ${BOLD}Secret/privacy scan passed — no obvious secrets or private data.${RESET}"
  exit 0
fi
fail "  Secret/privacy scan FAILED with $findings finding(s) above."
note "  Remove the secret from history if it was ever real (rotate it too), or"
note "  move a deliberate sample under an *.example name / fixture allowlist host."
exit 1
