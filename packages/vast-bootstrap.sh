#!/usr/bin/env bash
# vast-bootstrap.sh — Vast.ai PROVISIONING_SCRIPT entrypoint (public, secret-free).
#
# Fetched anonymously by the vastai base image at first boot. It (1) fetches the
# PINNED shared engine `provision-lib.sh` from nix-config, (2) clones the stack's
# provisioner repo — PUBLIC or PRIVATE — at a pinned ref, and (3) exec's the repo's
# provision.sh (whose exit code becomes THIS process's exit code, and thus the base
# image's Phase-9 status — the one honest wire out).
#
# Because provision-lib.sh does not exist until after the clone, this script carries a
# MINIMAL embedded funnel (classify_min + a raw status writer) so a failure to fetch the
# lib or clone the repo is itself funneled — a `PROVISION-OUTCOME: failed` marker + a
# provision-status.json + exit 1 — instead of a raw git error. This is the pre-clone twin
# of provision-lib.sh's classifier; keep it ≤ its auth/not-found/network arms.
#
# Template env (all non-secret; set by `vast-template-apply`):
#   PROVISION_LIB_URL     pinned raw URL of provision-lib.sh   (required for the engine)
#   PROVISION_HOST        github.com | gitlab.com              (default github.com)
#   PROVISION_REPO        owner/repo                           (required)
#   PROVISION_REF         commit SHA or branch                 (default main)
#   PROVISION_ENTRYPOINT  path within the repo                 (default provision.sh)
#   PROVISION_DIR         checkout dir                         (default /workspace/provision)
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

host="${PROVISION_HOST:-github.com}"
repo="${PROVISION_REPO:-}"
ref="${PROVISION_REF:-main}"
entry="${PROVISION_ENTRYPOINT:-provision.sh}"
dest="${PROVISION_DIR:-/workspace/provision}"
lib_url="${PROVISION_LIB_URL:-}"
lib_dest="${PROVISION_LIB:-/workspace/provision-lib.sh}"
status_file="${STATUS_FILE:-/workspace/provision-status.json}"

log() { printf '%s bootstrap: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Minimal, self-contained failure funnel (the lib isn't available yet).
classify_min() { # <rc> <errfile>
  local rc="$1" body; body="$(cat "${2:-/dev/null}" 2>/dev/null || true)"
  printf '%s' "$body" | grep -qiE 'authentication failed|permission denied|invalid.token|403 forbidden|remote: http basic|could not read (username|password)' && { echo auth-forbidden; return; }
  printf '%s' "$body" | grep -qiE "couldn't find remote ref|not found|does not exist|repository .* not found|reference is not a tree" && { echo not-found; return; }
  printf '%s' "$body" | grep -qiE 'could not resolve|connection (refused|reset|timed out)|network is unreachable|temporary failure in name resolution' && { echo network; return; }
  case "$rc" in 6|7|28|35|56) echo network; return ;; esac
  echo generic
}
_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
fail() { # <step-name> <class> <detail>
  local tmp="${status_file}.tmp"
  mkdir -p "$(dirname "$status_file")" 2>/dev/null || true
  printf '{\n  "schema_version": 1,\n  "outcome": "failed",\n  "overall": "failed",\n  "updated": %s,\n  "required_failed": 1,\n  "optional_failed": 0,\n  "steps": [\n    {"name": "%s", "required": true, "status": "failed", "error_class": "%s", "detail": "%s"}\n  ]\n}\n' \
    "$(date -u +%s)" "$(_esc "$1")" "$(_esc "$2")" "$(_esc "$3")" >"$tmp" 2>/dev/null && mv -f "$tmp" "$status_file" 2>/dev/null || true
  printf 'PROVISION-OUTCOME: failed (%s: %s)\n' "$1" "$2"
  echo "════════════════════════════════════════════════════════════"
  echo "  ❌ PROVISIONING FAILED at bootstrap"
  printf '  - [REQUIRED] %s (%s): %s\n' "$1" "$2" "$3"
  echo "════════════════════════════════════════════════════════════"
  exit 1
}

[ -n "$repo" ] || fail "bootstrap:env" generic "PROVISION_REPO is required"

# ---- 1. Fetch the pinned shared engine ----
if [ -n "$lib_url" ]; then
  log "fetching engine lib -> $lib_dest"
  err="$(mktemp)"
  if ! curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 -o "$lib_dest" "$lib_url" 2>"$err"; then
    fail "bootstrap:lib-fetch" "$(classify_min "$?" "$err")" "$(tail -c 300 "$err" | tr '\n' ' ')"
  fi
  [ -s "$lib_dest" ] || fail "bootstrap:lib-fetch" generic "fetched provision-lib.sh is empty"
elif [ -f "$dest/provision-lib.sh" ]; then
  lib_dest="$dest/provision-lib.sh"   # fallback: repo-vendored lib
else
  log "WARN: no PROVISION_LIB_URL and no vendored lib; provision.sh must be self-contained"
fi
export PROVISION_LIB="$lib_dest"

# ---- 2. Clone the stack provisioner repo at its pinned ref ----
case "$host" in
  gitlab.com) TOK="${GITLAB_TOKEN:-}" ;;
  github.com) TOK="${GH_TOKEN:-}" ;;
  *) TOK="" ;;
esac
export TOK
log "cloning ${host}/${repo}@${ref} -> ${dest}"
rm -rf "$dest"
err="$(mktemp)"
# Token via a credential helper that reads $TOK from the environment — never in argv,
# the remote URL, or the error output. An empty $TOK yields an anonymous (public) clone.
# shellcheck disable=SC2016
if ! git -c credential.helper='!f(){ echo username=oauth2; echo "password=$TOK"; }; f' \
        -c credential.useHttpPath=false \
        clone --quiet "https://${host}/${repo}.git" "$dest" 2>"$err"; then
  fail "bootstrap:clone" "$(classify_min "$?" "$err")" "clone ${host}/${repo}: $(tail -c 300 "$err" | tr '\n' ' ')"
fi
if ! git -C "$dest" checkout --quiet "$ref" 2>"$err"; then
  fail "bootstrap:checkout" "$(classify_min "$?" "$err")" "checkout ${ref}: $(tail -c 300 "$err" | tr '\n' ' ')"
fi
unset TOK

# ---- 3. Exec the stack entrypoint (its exit code becomes ours -> Phase 9's) ----
cd "$dest"
[ -f "$entry" ] || fail "bootstrap:entry" not-found "entrypoint '$entry' not in ${repo}@${ref}"
export PROVISION_REPO_DIR="$dest"
log "running $entry (engine: $PROVISION_LIB)"
exec bash "$entry"
