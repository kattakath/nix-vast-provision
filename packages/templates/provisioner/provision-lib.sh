#!/usr/bin/env bash
# provision-lib.sh — the SHARED, never-false-positive ComfyUI provisioning engine.
#
# Single-sourced from nix-config (packages/vast-templates/provisioner/) and fetched
# at a PINNED flake rev by vast-bootstrap.sh (env PROVISION_LIB_URL), which drops it
# on the instance and points PROVISION_LIB at it. A stack repo's provision.sh is then
# THIN: `source "$PROVISION_LIB"`, declare the maps, call `comfyui_provision`. The
# engine is identical for every stack — no per-repo copy, no fan-out.
#
# CORE INVARIANT — success is DERIVED, fails CLOSED, and is DISTINCT at every layer.
# Nothing ever *prints* "complete" from control flow. One ledger renders the exit code,
# a canonical `PROVISION-OUTCOME: ok|partial|failed` marker line, provision-status.json,
# and the banner. `provision.sh` exits 0 iff every REQUIRED step passed AND the tally is
# readable; an empty/garbled tally is treated as FAILED, never success.
#
# Config schemas the stack declares (each carries a required flag; required models MUST
# carry a sha256 — enforced at load):
#   MODEL_MAP   dest|host|id|required|sha256
#                 host=hf      id=<org/repo>/resolve/<rev>/<path>   (-> huggingface.co/<id>, Bearer HF_TOKEN)
#                 host=civitai id=<modelVersionId>                  (-> curl, ?token=CIVITAI_TOKEN; aria2 mishandles B2)
#                 host=url     id=<full-url>
#                 dest is relative to $COMFY/models (e.g. checkpoints/foo.safetensors)
#   NODES       url|commit|dir|extra|required
#   ALIAS_MAP   legacy:canon
#   WORKFLOW_MAP fname|source|required   (source empty => repo comfyui/<fname>; else a URL)
#   REQUIRE_TOKENS  (array) token names used by nodes/workflow/pip that MODEL_MAP can't reveal
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/ComfyUI}"
VENV="${VENV:-/venv/main}"
STATUS_FILE="${STATUS_FILE:-/workspace/provision-status.json}"
LOG_DIR="${LOG_DIR:-/workspace/provision-logs}"
SCHEMA_VERSION=1
_FINALIZED=0
WATCHDOG_PID=""
LEDGER=""
START_TS=""
DEADLINE_TS=""

log() { printf '%s provision: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ---------------------------------------------------------------------------
# Ledger + status rendering
# ---------------------------------------------------------------------------
_json_escape() { # <string> -> JSON-safe (no surrounding quotes)
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  printf '%s' "$s"
}

record() { # <name> <required 0|1> <status ok|failed> <class> <detail>
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$LEDGER" \
    || { printf 'PROVISION-OUTCOME: failed (ledger write error)\n'; exit 1; }
  write_status_json
}

write_status_json() {
  local overall rf of tmp="${STATUS_FILE}.tmp"
  overall="$(overall_verdict)"; rf="$(required_fail_count)"; of="$(optional_fail_count)"
  {
    printf '{\n'
    printf '  "schema_version": %s,\n' "$SCHEMA_VERSION"
    printf '  "outcome": "%s",\n' "$overall"
    printf '  "overall": "%s",\n' "$overall"
    printf '  "started": %s,\n' "${START_TS:-0}"
    printf '  "updated": %s,\n' "$(date -u +%s)"
    printf '  "deadline_ts": %s,\n' "${DEADLINE_TS:-0}"
    printf '  "required_failed": %s,\n' "$rf"
    printf '  "optional_failed": %s,\n' "$of"
    printf '  "steps": [\n'
    local first=1 name req status cls detail
    while IFS=$'\t' read -r name req status cls detail; do
      [ -n "$name" ] || continue
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '    {"name": "%s", "required": %s, "status": "%s", "error_class": "%s", "detail": "%s"}' \
        "$(_json_escape "$name")" "$([ "$req" = 1 ] && echo true || echo false)" \
        "$(_json_escape "$status")" "$(_json_escape "$cls")" "$(_json_escape "$detail")"
    done <"$LEDGER"
    printf '\n  ]\n}\n'
  } >"$tmp" 2>/dev/null || { printf 'PROVISION-OUTCOME: failed (status write error)\n'; exit 1; }
  mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || { printf 'PROVISION-OUTCOME: failed (status mv error)\n'; exit 1; }
}

# ---------------------------------------------------------------------------
# Dynamic failure classifier — self-protecting, always prints ONE token, returns 0
# ---------------------------------------------------------------------------
classify() { # <rc> <output-file>
  set +e
  local rc="$1" f="$2" body avail code
  body="$(cat "$f" 2>/dev/null || true)"
  avail="$(df -P /workspace 2>/dev/null | awk 'NR==2{print $4}')"; avail="${avail:-999999999}"
  printf '%s' "$body" | grep -qiE 'no space left|ENOSPC|write error|failure writing' && { echo disk-full; return 0; }
  [ "$avail" -lt 102400 ] 2>/dev/null && { echo disk-full; return 0; }
  code="$(printf '%s' "$body" | grep -oE 'HTTPSTATUS:[0-9]{3}' | tail -1 | cut -d: -f2)"
  case "$code" in
    401|403) echo auth-forbidden; return 0 ;;
    404|410) echo not-found; return 0 ;;
    429)     echo rate-limited; return 0 ;;
    5??)     echo server-error; return 0 ;;
  esac
  printf '%s' "$body" | grep -qiE 'sha256 mismatch|checksum.*mismatch|size mismatch|not a valid.*(zip|safetensors)|<html' && { echo hash-mismatch; return 0; }
  printf '%s' "$body" | grep -qiE 'authentication failed|permission denied|invalid.token|401 unauthorized|remote: http basic|gated|awaiting.*approval|access to model.*is restricted' && { echo auth-forbidden; return 0; }
  printf '%s' "$body" | grep -qiE "couldn't find remote ref|does not exist|no such|reference is not a tree|revision.*not found" && { echo not-found; return 0; }
  printf '%s' "$body" | grep -qiE 'could not resolve|connection (refused|reset|timed out)|network is unreachable|temporary failure in name resolution|signature.*expired|request has expired' && { echo network; return 0; }
  case "$rc" in
    6|7|28|35|56) echo network; return 0 ;;
    18|33|36) echo truncated; return 0 ;;
    23) echo disk-full; return 0 ;;
  esac
  printf '%s' "$body" | grep -qiE 'ERROR: (could not|failed building)|modulenotfounderror|subprocess-exited|no matching distribution' && { echo dependency; return 0; }
  echo generic; return 0
}

# ---------------------------------------------------------------------------
# step wrapper — runs a command, records the outcome, ALWAYS returns 0
# ---------------------------------------------------------------------------
step() { # <name> <required 0|1> -- <cmd...>
  local name="$1" required="$2"; shift 2; [ "${1:-}" = "--" ] && shift
  local out rc=0 cls detail
  out="$(mktemp "${LOG_DIR}/step.XXXXXX")"
  log "▶ ${name} (required=${required})"
  ( "$@" ) >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$name" "$required" ok none ""
    log "✔ ${name}"; rm -f "$out"; return 0
  fi
  cls="$(classify "$rc" "$out")"
  detail="$(tail -c 400 "$out" 2>/dev/null | tr '\n' ' ' | tr -cd '[:print:] ' || true)"
  record "$name" "$required" failed "$cls" "$detail"
  if [ "$required" -eq 1 ]; then
    log "✗ REQUIRED FAILED ${name} [${cls}] rc=${rc}"
  else
    log "⚠ optional failed ${name} [${cls}] rc=${rc} (continuing)"
  fi
  rm -f "$out"; return 0
}

# ---------------------------------------------------------------------------
# Derived verdict — FAIL-CLOSED (empty/non-numeric required tally => failed)
# ---------------------------------------------------------------------------
_count() { awk -F'\t' -v r="$1" '$2==r && $3!="ok"{n++} END{print n+0}' "$LEDGER" 2>/dev/null; }
required_fail_count() { local n; n="$(_count 1)"; case "$n" in ''|*[!0-9]*) echo 1 ;; *) echo "$n" ;; esac; }
optional_fail_count() { local n; n="$(_count 0)"; case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac; }
overall_verdict() {
  [ "$(required_fail_count)" -gt 0 ] && { echo failed; return; }
  [ "$(optional_fail_count)" -gt 0 ] && { echo partial; return; }
  echo ok
}

retry() { # <tries> <cmd...>
  local n="$1"; shift; local i=0
  until "$@"; do i=$((i+1)); [ "$i" -ge "$n" ] && return 1; sleep 5; done
}

short_circuit() {
  [ "$(required_fail_count)" -gt 0 ] && { log "REQUIRED failure — aborting remaining phases."; exit 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Finalize / trap funnel — single banner + canonical marker, idempotent
# ---------------------------------------------------------------------------
maybe_webhook() { # <outcome> <required_failed>
  local url="${PROVISIONER_WEBHOOK_URL:-}" cid="${CONTAINER_ID:-}" body sig
  [ -n "$url" ] || return 0
  [ -n "$cid" ] || { log "webhook skipped: CONTAINER_ID empty"; return 0; }
  body="$(printf '{"outcome":"%s","required_failed":%s,"container_id":"%s","timestamp":%s}' \
    "$1" "$2" "$(_json_escape "$cid")" "$(date -u +%s)")"
  if [ -n "${PROVISIONER_WEBHOOK_SECRET:-}" ] && command -v openssl >/dev/null 2>&1; then
    sig="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$PROVISIONER_WEBHOOK_SECRET" 2>/dev/null | awk '{print $NF}')"
    curl -fsS -m 15 -X POST -H 'Content-Type: application/json' -H "X-Provisioner-Signature: sha256=${sig}" -d "$body" "$url" >/dev/null 2>&1 \
      || log "webhook POST failed (non-fatal)"
  else
    curl -fsS -m 15 -X POST -H 'Content-Type: application/json' -d "$body" "$url" >/dev/null 2>&1 \
      || log "webhook POST failed (non-fatal)"
  fi
}

finalize() {
  [ "$_FINALIZED" = 1 ] && return 0
  _FINALIZED=1
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
  write_status_json
  local o rf of; o="$(overall_verdict)"; rf="$(required_fail_count)"; of="$(optional_fail_count)"
  printf 'PROVISION-OUTCOME: %s (%s required, %s optional failed)\n' "$o" "$rf" "$of"
  echo "════════════════════════════════════════════════════════════"
  if [ "$o" = ok ]; then
    echo "  ✅ PROVISIONING COMPLETE — all required steps OK"
  else
    printf '  %s PROVISIONING %s — %s REQUIRED, %s optional failed\n' \
      "$([ "$o" = failed ] && echo '❌' || echo '⚠️')" "$(printf '%s' "$o" | tr '[:lower:]' '[:upper:]')" "$rf" "$of"
    echo "  Reasons:"
    awk -F'\t' '$3!="ok"{printf "    - [%s] %s (%s)\n",($2=="1"?"REQUIRED":"optional"),$1,$4}' "$LEDGER" 2>/dev/null || true
  fi
  echo "  status: ${STATUS_FILE}"
  echo "════════════════════════════════════════════════════════════"
  maybe_webhook "$o" "$rf"
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$(required_fail_count)" -eq 0 ]; then
    record "runtime:unhandled" 1 failed generic "aborted rc=${rc}"
  fi
  finalize
  [ "$(required_fail_count)" -gt 0 ] && exit 1
  exit 0
}

start_watchdog() {
  local secs="${PROVISION_MAX_SECONDS:-5400}" main=$$
  DEADLINE_TS=$(( $(date -u +%s) + secs ))
  ( sleep "$secs"
    kill -0 "$main" 2>/dev/null || exit 0
    record "runtime:timeout" 1 failed timeout "exceeded ${secs}s"
    kill -TERM "$main" 2>/dev/null || true ) &
  WATCHDOG_PID=$!
}

# ---------------------------------------------------------------------------
# HTTP download — curl only (aria2 mishandles Civitai's signed B2 redirect => 403).
# Emits HTTPSTATUS:NNN; sha256 is a HARD gate; never resumes without a sha to verify.
# ---------------------------------------------------------------------------
fetch_http() { # <dest> <url> [sha256] [auth-header]
  local dest="$1" url="$2" want="${3:-}" auth="${4:-}" tmp="$1.part" code rc
  mkdir -p "$(dirname "$dest")"
  if [ -n "$want" ] && [ -f "$dest" ] && [ "$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')" = "$want" ]; then
    echo "cached ok"; return 0
  fi
  local resume=() hdr=()
  if [ -n "$want" ] && [ -f "$tmp" ]; then resume=(-C -); else rm -f "$tmp"; fi
  [ -n "$auth" ] && hdr=(-H "$auth")
  set +e
  code="$(curl -sSL "${resume[@]}" "${hdr[@]}" --retry 5 --retry-delay 3 --retry-connrefused \
        --connect-timeout 30 --max-time "${MODEL_MAX_TIME:-3600}" \
        -o "$tmp" -w '%{http_code}' "$url" 2>>"${LOG_DIR}/curl.err")"; rc=$?
  set -e
  echo "HTTPSTATUS:${code:-000}"
  tail -c 400 "${LOG_DIR}/curl.err" 2>/dev/null >&2 || true
  [ "$rc" -eq 0 ] || { echo "curl rc=${rc}"; return "$rc"; }
  case "$code" in 2??) : ;; *) echo "bad status ${code}"; return 1 ;; esac
  if [ -z "$want" ] && head -c 512 "$tmp" 2>/dev/null | grep -qiE '<!doctype html|<html'; then
    echo "html body, not a file"; rm -f "$tmp"; return 1
  fi
  if [ -n "$want" ]; then
    local got; got="$(sha256sum "$tmp" | awk '{print $1}')"
    [ "$got" = "$want" ] || { echo "sha256 mismatch want=${want} got=${got}"; rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$dest"
}
fetch_hf()      { fetch_http "$1" "https://huggingface.co/$2" "${3:-}" "Authorization: Bearer ${HF_TOKEN:-}"; }
fetch_civitai() { fetch_http "$1" "https://civitai.com/api/download/models/$2?token=${CIVITAI_TOKEN:-}" "${3:-}"; }

# ---------------------------------------------------------------------------
# Preflight probes — fail in seconds, before the long downloads
# ---------------------------------------------------------------------------
tool_probe() {
  local t missing=""
  for t in curl git sha256sum base64 df awk mktemp; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
  done
  [ -z "$missing" ] || { echo "missing tools:${missing}"; return 1; }
}

hf_probe() {
  [ -n "${HF_TOKEN:-}" ] || { echo "HTTPSTATUS:401 no HF_TOKEN"; return 1; }
  local c; c="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${HF_TOKEN}" https://huggingface.co/api/whoami-v2)"
  echo "HTTPSTATUS:${c}"; [ "$c" = 200 ]
}
civitai_probe() {
  [ -n "${CIVITAI_TOKEN:-}" ] || { echo "HTTPSTATUS:401 no CIVITAI_TOKEN"; return 1; }
  local c; c="$(curl -s -o /dev/null -w '%{http_code}' "https://civitai.com/api/v1/models?limit=1&token=${CIVITAI_TOKEN}")"
  echo "HTTPSTATUS:${c}"; [ "$c" = 200 ]
}
gh_probe() {
  local tok="${GH_TOKEN:-${GITLAB_TOKEN:-}}"
  [ -n "$tok" ] || { echo "no GH/GITLAB token"; return 1; }
  return 0
}
repo_probe() { GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$1" >/dev/null 2>&1 || { echo "HTTPSTATUS:404 ls-remote $1"; return 1; }; }

disk_probe() {
  local floor="${PROVISION_DISK_FLOOR_KB:-5242880}" avail
  avail="$(df -P /workspace 2>/dev/null | awk 'NR==2{print $4}')"; avail="${avail:-0}"
  [ "$avail" -ge "$floor" ] 2>/dev/null || { echo "disk headroom ${avail}KB < floor ${floor}KB"; return 1; }
}

supervisor_probe() {
  # Authoritative paths from vast-ai/base-image: master config + drop-in conf.d, and a
  # ROOT-ONLY socket at /var/run/supervisor.sock that is ONLY discoverable via -c (the
  # bare `supervisorctl` default looks at ./ or /etc/supervisord.conf and never finds it).
  SUPERVISORD_CONF=/etc/supervisor/supervisord.conf
  SUPERVISOR_CONFD=/etc/supervisor/conf.d
  command -v supervisorctl >/dev/null 2>&1 || { echo "supervisorctl not found on PATH"; return 1; }
  [ -f "$SUPERVISORD_CONF" ] || { echo "missing $SUPERVISORD_CONF (not the vastai base image?)"; return 1; }
  mkdir -p "$SUPERVISOR_CONFD"
  # supervisord is launched (backgrounded) by vast_boot.d just before the Phase-9
  # provisioning script, so briefly retry the socket. Reachability is tested with `pid`
  # (returns supervisord's PID, exit 0 iff the daemon is reachable) — NOT `status`, which
  # exits non-zero whenever ANY program is down (e.g. a base service still starting), which
  # is not a reachability failure. This was the bug that failed preflight:supervisor.
  local i=0
  until supervisorctl -c "$SUPERVISORD_CONF" pid >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 8 ] && { echo "supervisorctl -c $SUPERVISORD_CONF cannot reach the daemon (socket /var/run/supervisor.sock is root-only)"; return 1; }
    sleep 3
  done
  # step runs us in a subshell, so `export` here would not reach the parent — persist the
  # resolved paths to a file the parent sources after the step.
  printf 'SUPERVISORD_CONF=%q\nSUPERVISOR_CONFD=%q\n' "$SUPERVISORD_CONF" "$SUPERVISOR_CONFD" >"$LOG_DIR/supervisor.env"
}

needed_tokens() {
  local m host; declare -A want=()
  for m in "${MODEL_MAP[@]:-}"; do
    [ -n "$m" ] || continue
    host="$(printf '%s' "$m" | cut -d'|' -f2)"
    case "$host" in hf) want[hf]=1 ;; civitai) want[civitai]=1 ;; esac
  done
  local t
  for t in "${REQUIRE_TOKENS[@]:-}"; do [ -n "$t" ] && want[$t]=1; done
  for t in "${!want[@]}"; do printf '%s\n' "$t"; done
}

preflight() {
  log "── PREFLIGHT ──"
  step "preflight:tools" 1 -- tool_probe
  step "preflight:supervisor" 1 -- supervisor_probe
  # shellcheck source=/dev/null
  [ -f "$LOG_DIR/supervisor.env" ] && . "$LOG_DIR/supervisor.env"
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    step "preflight:${t}-token" 1 -- retry 3 "${t}_probe"
  done < <(needed_tokens)
  local n url commit dir extra req
  for n in "${NODES[@]:-}"; do
    [ -n "$n" ] || continue
    IFS='|' read -r url commit dir extra req <<<"$n"
    step "preflight:ls-remote $(basename "${url%.git}")" "${req:-1}" -- retry 3 repo_probe "$url"
  done
  step "preflight:disk" 1 -- disk_probe
  short_circuit
}

# ---------------------------------------------------------------------------
# ComfyUI engine
# ---------------------------------------------------------------------------
_pip() { if [ -x "$VENV/bin/pip" ]; then "$VENV/bin/pip" "$@"; else python3 -m pip "$@"; fi; }

_clone_comfyui() {
  local tmpc; tmpc="$(mktemp -d)"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI "$tmpc/ComfyUI"
  mkdir -p "$COMFY"; cp -rn "$tmpc/ComfyUI/." "$COMFY/"; rm -rf "$tmpc"
}

install_comfyui() {
  log "── COMFYUI ──"
  if [ ! -f "$COMFY/main.py" ]; then
    step "comfyui:clone" 1 -- _clone_comfyui
    short_circuit
    step "comfyui:requirements" 1 -- _pip install --no-input -r "$COMFY/requirements.txt"
  else
    log "ComfyUI already present at $COMFY"
  fi
  mkdir -p "$COMFY/custom_nodes" "$COMFY/models"
  short_circuit
}

install_nodes() {
  log "── NODES ──"
  local nodes_dir="$COMFY/custom_nodes" entry url commit dir extra req dest
  for entry in "${NODES[@]:-}"; do
    [ -n "$entry" ] || continue
    IFS='|' read -r url commit dir extra req <<<"$entry"
    req="${req:-1}"
    [ -n "$dir" ] || dir="$(basename "${url%.git}")"
    dest="$nodes_dir/$dir"
    if [ -d "$dest/.git" ]; then
      step "node:${dir}:fetch" 0 -- git -C "$dest" fetch --quiet --all
    else
      step "node:${dir}:clone" "$req" -- git clone --quiet "$url" "$dest"
    fi
    [ -d "$dest/.git" ] && [ -n "$commit" ] && step "node:${dir}:checkout" "$req" -- git -C "$dest" checkout --quiet "$commit"
    [ -f "$dest/requirements.txt" ] && step "node:${dir}:pip" "$req" -- _pip install --no-input -r "$dest/requirements.txt"
    [ -n "${extra:-}" ] && step "node:${dir}:pip-extra" "$req" -- _pip install --no-input "$extra"
  done
  local a legacy canon
  for a in "${ALIAS_MAP[@]:-}"; do
    [ -n "$a" ] || continue
    legacy="${a%%:*}"; canon="${a##*:}"
    [ -d "$nodes_dir/$canon" ] && [ ! -e "$nodes_dir/$legacy" ] && ln -s "$canon" "$nodes_dir/$legacy" 2>/dev/null || true
  done
  short_circuit
}

download_models() {
  log "── MODELS ──"
  local models_dir="$COMFY/models" entry dest host id req sha nm
  for entry in "${MODEL_MAP[@]:-}"; do
    [ -n "$entry" ] || continue
    IFS='|' read -r dest host id req sha <<<"$entry"
    req="${req:-1}"
    nm="model:$(basename "$dest")"
    if [ "$req" = 1 ] && [ -z "$sha" ]; then
      record "config:${nm}" 1 failed generic "required model has no sha256"
      log "✗ REQUIRED ${nm}: missing sha256 in config"
      continue
    fi
    case "$host" in
      hf)      step "$nm" "$req" -- fetch_hf      "$models_dir/$dest" "$id" "$sha" ;;
      civitai) step "$nm" "$req" -- fetch_civitai "$models_dir/$dest" "$id" "$sha" ;;
      url)     step "$nm" "$req" -- fetch_http    "$models_dir/$dest" "$id" "$sha" ;;
      *)       record "$nm" "$req" failed generic "unknown host '${host}'" ;;
    esac
  done
  short_circuit
}

place_workflow() {
  log "── WORKFLOW ──"
  local wf_dir="$COMFY/user/default/workflows" entry fname source req
  mkdir -p "$wf_dir"
  for entry in "${WORKFLOW_MAP[@]:-}"; do
    [ -n "$entry" ] || continue
    IFS='|' read -r fname source req <<<"$entry"
    req="${req:-1}"
    if [ -z "$source" ] && [ -f "${PROVISION_REPO_DIR:-.}/comfyui/$fname" ]; then
      step "workflow:${fname}" "$req" -- cp "${PROVISION_REPO_DIR:-.}/comfyui/$fname" "$wf_dir/$fname"
    elif [ -n "$source" ]; then
      step "workflow:${fname}" "$req" -- fetch_http "$wf_dir/$fname" "$source"
    else
      record "workflow:${fname}" "$req" failed not-found "workflow file absent in repo and no source URL"
    fi
  done
  short_circuit
}

setup_ssh() {
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  local key; key="$(printf '%s' "${SSH_PUBKEY_B64:-}" | base64 -d 2>/dev/null || true)"
  [ -n "$key" ] || { echo "empty/invalid SSH_PUBKEY_B64"; return 1; }
  printf '%s\n' "$key" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1 || { echo "SSH_PUBKEY_B64 is not a valid public key"; return 1; }
  grep -qxF "$key" /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$key" >>/root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
}

comfyui_ready() { # <tries>
  local t="$1" i=0
  until curl -fsS -o /dev/null "http://127.0.0.1:18188/system_stats" \
     || curl -fsS -o /dev/null "http://127.0.0.1:18188/"; do
    i=$((i+1)); [ "$i" -ge "$t" ] && { echo "ComfyUI never served on :18188"; return 1; }; sleep 5
  done
  supervisorctl -c "${SUPERVISORD_CONF:-/etc/supervisor/supervisord.conf}" status comfyui 2>/dev/null | grep -q RUNNING \
    || supervisorctl status comfyui 2>/dev/null | grep -q RUNNING \
    || { echo "comfyui not RUNNING under supervisor"; return 1; }
}
port_open() { # <host> <port>
  local h="$1" p="$2" i=0
  until { command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${p} "; } \
     || { (exec 3<>"/dev/tcp/${h}/${p}") 2>/dev/null && exec 3>&- 3<&-; }; do
    i=$((i+1)); [ "$i" -ge 12 ] && { echo "port ${p} not listening"; return 1; }; sleep 5
  done
}

start_services() {
  log "── SERVICES ──"
  # SSH is a debugging convenience — the Instance Portal is the primary access path, and
  # the base image may not run sshd under runtype=args. Plant the key + probe :22, but
  # keep both OPTIONAL so an SSH gap yields `partial`, never a failed provision. ComfyUI
  # (svc:comfyui-up) is the REQUIRED deliverable.
  step "svc:ssh-key" 0 -- setup_ssh
  local scripts_dir=/opt/supervisor-scripts confd="${SUPERVISOR_CONFD:-/etc/supervisor/conf.d}"
  mkdir -p "$scripts_dir" "$confd"
  # Wrapper: activate the base image's venv and exec ComfyUI in the FOREGROUND so
  # supervisord tracks its direct child (backgrounding is what got services reaped
  # before). Log to /dev/stdout so output reaches the Vast logs + Instance Portal.
  cat >"$scripts_dir/comfyui.sh" <<EOF
#!/usr/bin/env bash
source "${VENV}/bin/activate"
cd "$COMFY"
exec python main.py --listen 127.0.0.1 --port 18188
EOF
  chmod +x "$scripts_dir/comfyui.sh"
  # Program stanza modelled on the base image's own conf.d entries (autorestart on
  # unexpected exit, start-group semantics, stdout to the log pipeline).
  cat >"$confd/comfyui.conf" <<EOF
[program:comfyui]
environment=PROC_NAME="%(program_name)s"
command=$scripts_dir/comfyui.sh
autostart=true
autorestart=unexpected
exitcodes=0
startsecs=5
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=10
stdout_logfile=/dev/stdout
redirect_stderr=true
stdout_events_enabled=true
stdout_logfile_maxbytes=0
stdout_logfile_backups=0
EOF
  step "svc:reload" 1 -- supervisorctl -c "${SUPERVISORD_CONF:-/etc/supervisor/supervisord.conf}" reread
  step "svc:update" 1 -- supervisorctl -c "${SUPERVISORD_CONF:-/etc/supervisor/supervisord.conf}" update
  step "svc:comfyui-up" 1 -- comfyui_ready 60
  step "svc:sshd-up" 0 -- port_open 127.0.0.1 22
}

# ---------------------------------------------------------------------------
# Entry point the stack's thin provision.sh calls after declaring its maps.
# ---------------------------------------------------------------------------
comfyui_provision() {
  mkdir -p "$LOG_DIR" "$(dirname "$STATUS_FILE")"
  LEDGER="$(mktemp "${LOG_DIR}/ledger.XXXXXX")"
  START_TS="$(date -u +%s)"
  trap on_exit EXIT
  trap 'log "ERR at line $LINENO rc=$?"' ERR
  trap 'exit 143' TERM INT
  write_status_json
  start_watchdog
  preflight
  install_comfyui; short_circuit
  download_models; short_circuit
  install_nodes;   short_circuit
  place_workflow;  short_circuit
  start_services
  # on_exit derives the verdict, marker, exit code.
}
