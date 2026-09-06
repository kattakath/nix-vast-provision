# Vast.ai template-provisioning toolkit — the macOS-side, all-Nix companion to
# ./vast-bootstrap.sh and ./templates/provisioner/. Returns `writeShellApplication`s
# (shellcheck'd at `nix flake check`) plus a lint derivation for the committed
# instance-side scripts, wired as flake apps in flake.nix:
#
#   nix run .#vast-template-apply    — create/REPLACE (reconcile by name — delete+create)
#                                      a Vast.ai template; three modes: legacy repo-mode
#                                      (bash engine on vastai/base-image), aggregator mode
#                                      (--repo + --workflow-name, native provisioner against
#                                      a private aggregator repo), and manifest mode
#                                      (--manifest + --workflow, native provisioner against
#                                      a caller-supplied, rev-pinned manifest+workflow —
#                                      override orgName/repoName/rev via callPackage to point
#                                      at YOUR repo's committed manifest). Gated by
#                                      vast-repo-check unless --skip-check.
#   nix run .#vast-repo-check        — validate that a repo is a legit provisioner
#                                      repo (structural: .provisioner-template.json
#                                      marker + required files; forge-agnostic)
#   nix run .#vast-account-vars-set  — sync read-only Keychain tokens to Vast
#                                      ACCOUNT-level env vars (same name both sides)
#   nix run .#vast-ssh-key-set       — register the operator SSH public key on the Vast
#                                      account (idempotent)
#   nix run .#vast-init-repo         — scaffold a provisioner repo from the baked
#                                      templates/provisioner/ (GitHub or GitLab)
#   nix run .#vast-rent              — rent a live BILLED instance from a template by
#                                      name/hash, auto-selecting an on-demand offer;
#                                      injects an authenticated Docker Hub image_login
#                                      (DOCKERHUB_TOKEN) at create-time only
#
# Design (see the README): no custom image, no registry auth; PROVISIONING_SCRIPT ->
# committed public bootstrap (pinned to a chosen flake rev) -> clone the target repo
# (public/private, token from account vars) -> run its constant, self-contained
# provision.sh. Secrets NEVER touch the template. macOS-only: VAST_API_KEY plus the
# synced tokens live in the login Keychain (`/usr/bin/security`); curl/jq pinned via
# runtimeInputs.
#
# orgName/repoName/rev select WHICH repo's raw files the generated template's
# PROVISIONING_SCRIPT points at (i.e. where vast-bootstrap.sh + provision-lib.sh are
# fetched from at instance-boot time) — this ALSO governs manifest mode's rawBase
# (where a --manifest/--workflow path resolves to). They default to this flake's own
# GitHub coordinates (see flake.nix) so the toolkit works out of the box — override
# them if you forked this repo, or if you want manifest mode to serve YOUR OWN
# manifest+workflow files from your own repo instead of this one, e.g.:
#   callPackage ./packages/vast-provision.nix {
#     orgName = "your-org"; repoName = "your-fork"; rev = "abc123...";
#   }
{
  writeShellApplication,
  runCommand,
  curl,
  jq,
  gnused,
  coreutils,
  gh,
  glab,
  git,
  shellcheck,
  orgName,
  repoName,
  userName,
  rev,
}:
let
  api = "https://console.vast.ai/api/v0";
  # ?v=${rev} makes the URL change on every content change, defeating the base image's
  # Phase-9 URL-hash idempotency skip (so a fixed bootstrap actually re-runs).
  bootstrapUrl = "https://raw.githubusercontent.com/${orgName}/${repoName}/${rev}/packages/vast-bootstrap.sh?v=${rev}";
  # The shared, never-false-positive engine, pinned to this rev; the bootstrap fetches it.
  libUrl = "https://raw.githubusercontent.com/${orgName}/${repoName}/${rev}/packages/templates/provisioner/provision-lib.sh";
  # Pinned raw base for manifest-mode artifacts (a caller's own provisioning.yaml +
  # workflow JSON, committed in THEIR repo) — vast-template-apply builds rev-pinned
  # URLs against whatever --manifest/--workflow paths the caller passes. Governed by
  # the same orgName/repoName/rev override as bootstrapUrl/libUrl above.
  rawBase = "https://raw.githubusercontent.com/${orgName}/${repoName}/${rev}";

  # Validate that a repo is a legitimate provisioner repo — structurally (forge
  # provenance is asymmetric: GitHub has template_repository, GitLab has nothing),
  # by fetching ONLY the marker + required files via each forge's single-file API.
  repo-check = writeShellApplication {
    name = "vast-repo-check";
    runtimeInputs = [
      curl
      jq
      gnused
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"
      repo=""
      ref="main"
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo) repo="''${2:?}"; shift 2 ;;
          --ref) ref="''${2:?}"; shift 2 ;;
          -h | --help) echo "usage: vast-repo-check --repo [github:|gitlab:]owner/repo [--ref REF]"; exit 0 ;;
          *) echo "vast-repo-check: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -n "$repo" ] || { echo "vast-repo-check: --repo is required." >&2; exit 1; }

      host="github.com"
      case "$repo" in
        gitlab:*) host="gitlab.com"; repo="''${repo#gitlab:}" ;;
        github:*) host="github.com"; repo="''${repo#github:}" ;;
      esac

      # Fetch one file's raw contents (empty output + nonzero on 404/denied).
      fetch_file() {
        local path="$1" tok
        case "$host" in
          github.com)
            tok="$("$security" find-generic-password -a "$account" -s GH_TOKEN -w 2>/dev/null || true)"
            curl -fsSL -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github.raw+json" \
              "https://api.github.com/repos/$repo/contents/$path?ref=$ref" ;;
          gitlab.com)
            tok="$("$security" find-generic-password -a "$account" -s GITLAB_TOKEN -w 2>/dev/null || true)"
            local enc pe
            enc="$(printf '%s' "$repo" | sed 's|/|%2F|g')"
            pe="$(printf '%s' "$path" | sed 's|/|%2F|g')"
            curl -fsSL -H "PRIVATE-TOKEN: $tok" \
              "https://gitlab.com/api/v4/projects/$enc/repository/files/$pe/raw?ref=$ref" ;;
        esac
      }

      marker="$(fetch_file ".provisioner-template.json" 2>/dev/null || true)"
      if [ -z "$marker" ]; then
        echo "vast-repo-check: FAIL — $host/$repo@$ref has no .provisioner-template.json (not a provisioner repo)." >&2
        exit 1
      fi
      schema="$(printf '%s' "$marker" | jq -r '.schema // empty' 2>/dev/null || true)"
      tmpl="$(printf '%s' "$marker" | jq -r '.template // empty' 2>/dev/null || true)"
      if [ "$schema" != "1" ]; then
        echo "vast-repo-check: FAIL — unsupported marker schema '$schema' (expected 1)." >&2
        exit 1
      fi

      ok=1
      while IFS= read -r rf; do
        [ -n "$rf" ] || continue
        if ! fetch_file "$rf" >/dev/null 2>&1; then
          echo "vast-repo-check: FAIL — required file '$rf' missing." >&2
          ok=0
        fi
      done < <(printf '%s' "$marker" | jq -r '(.required_files // ["provision.sh"])[]' 2>/dev/null)
      [ "$ok" = 1 ] || exit 1

      echo "vast-repo-check: OK — $host/$repo@$ref (template=$tmpl schema=$schema)."
    '';
  };

  template-apply = writeShellApplication {
    name = "vast-template-apply";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      # Reconcile (create or REPLACE, by name) a Vast.ai template whose instances boot
      # via PROVISIONING_SCRIPT -> bootstrap -> clone target repo -> run provision.sh.
      # Gated by vast-repo-check (skip with --skip-check). No secrets in the template.
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s VAST_API_KEY -w 2>/dev/null || true)"
      if [ -z "$apikey" ]; then
        echo "vast-template-apply: VAST_API_KEY not in the login Keychain (see README: 'secret set VAST_API_KEY')." >&2
        exit 1
      fi

      name=""
      repo=""
      ref="main"
      entry="provision.sh"
      manifest=""
      workflow=""
      wfname=""
      image=""
      disk=""
      host=""
      tag=""
      dryrun=""
      skipcheck=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --template-name) name="''${2:?}"; shift 2 ;;
          --repo) repo="''${2:?}"; shift 2 ;;
          --ref) ref="''${2:?}"; shift 2 ;;
          --entrypoint) entry="''${2:?}"; shift 2 ;;
          --manifest) manifest="''${2:?}"; shift 2 ;;
          --workflow) workflow="''${2:?}"; shift 2 ;;
          --workflow-name) wfname="''${2:?}"; shift 2 ;;
          --image) image="''${2:?}"; shift 2 ;;
          --disk) disk="''${2:?}"; shift 2 ;;
          --dry-run) dryrun=1; shift ;;
          --skip-check) skipcheck=1; shift ;;
          -h | --help)
            echo "usage: vast-template-apply --template-name NAME (--repo OWNER/REPO | --manifest PATH --workflow PATH) \\"
            echo "  repo mode (legacy):  --repo [github:|gitlab:]owner/repo [--ref REF] [--entrypoint PATH]  (bash engine on vastai/base-image)"
            echo "  aggregator mode:     --repo gitlab:owner/comfyui-workflows --workflow-name NAME  (native provisioner on vastai/comfy; private OK)"
            echo "  manifest mode:       --manifest packages/…/provisioning.yaml --workflow packages/…/workflow.json  (native provisioner from a public URL)"
            echo "  common:              [--image IMG[:TAG]] [--disk GB] [--dry-run] [--skip-check]"
            exit 0 ;;
          *) echo "vast-template-apply: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -n "$name" ] || { echo "vast-template-apply: --template-name is required." >&2; exit 1; }

      pubkey_b64="$(base64 < "$HOME/.ssh/id_ed25519.pub" 2>/dev/null | tr -d '\n' || true)"
      # Fail LOUDLY rather than shipping an empty SSH_PUBKEY_B64 (a login-less instance).
      [ -n "$pubkey_b64" ] || { echo "vast-template-apply: ~/.ssh/id_ed25519.pub not found — cannot inject SSH_PUBKEY_B64" >&2; exit 1; }

      # Two branches below: manifest mode, and repo mode (which covers both the aggregator and
      # legacy flavours). All use runtype=args (base image entrypoint intact: supervisord + Instance
      # Portal + the /etc/vast_boot.d provisioning hook). OPEN_BUTTON_PORT=1111 renders the Open
      # button; PORTAL_CONFIG lists apps; SSH_PUBKEY_B64 is planted for sshd.
      #
      # PORTAL_CONFIG entry FORMAT: hostname:external_port:internal_port:/path:Name — external is the
      # Caddy TLS+auth listen port Vast publishes (1111/8188, matched by the -p flags below); internal
      # is the raw loopback the app binds (11111/18188, NEVER published). Two things are load-bearing,
      # both matching Vast's own stock ComfyUI template verbatim:
      #   1. The first entry MUST be named "Instance Portal". Each service's supervisor wrapper only
      #      starts if its entry appears in /etc/portal.yaml (generated from these NAMES); the portal
      #      backend's wrapper greps for the case-insensitive substring "instance portal", so a plain
      #      "Portal" makes it SKIP launching the FastAPI backend on 127.0.0.1:11111 — Caddy on :1111
      #      then 502s every request and the console Open button hangs on "Connecting..." forever.
      #   2. The value MUST be double-quoted. Vast re-parses the stored template `env` field shell-style
      #      (splitting on whitespace), so the SPACE in "Instance Portal" truncates an UNQUOTED value at
      #      the space: the portal entry degrades to name "Instance" (still no match → 502) AND the
      #      trailing "|...:ComfyUI" splits off as a stray token, dropping the ComfyUI entry too (comfyui
      #      then also "Skipping ... not in /etc/portal.yaml" → :8188 dead). Quoting keeps it intact.
      # (Root-caused from a live instance log + vast-ai/base-image source + Vast's stock comfy template.)
      if [ -n "$manifest" ]; then
        # MANIFEST MODE — Vast's NATIVE provisioner (PROVISIONING_MANIFEST) on the pre-baked
        # vastai/comfy image (ComfyUI + venv + comfyui service already there). No bootstrap,
        # no engine lib; the manifest + a rev-pinned WORKFLOW_URL drive everything. No repo to
        # legitimacy-check. The manifest/workflow are committed in the repo orgName/repoName/rev
        # point at (this flake's own by default — override via callPackage for your own repo).
        [ -n "$workflow" ] || { echo "vast-template-apply: --workflow is required in manifest mode." >&2; exit 1; }
        [ -z "$image" ] && image="vastai/comfy"
        tag="v0.28.0-cuda-12.9-py312"
        case "$image" in *:*) tag="''${image##*:}"; image="''${image%:*}" ;; esac
        [ -z "$disk" ] && disk="100"
        manifest_url="${rawBase}/$manifest?v=${rev}"
        workflow_url="${rawBase}/$workflow?v=${rev}"
        env_str="-e PROVISIONING_MANIFEST=$manifest_url -e WORKFLOW_URL=$workflow_url -e PROVISIONER_FAILURE_ACTION=stop -e OPEN_BUTTON_PORT=1111 -e PORTAL_CONFIG=\"localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI\" -e SSH_PUBKEY_B64=$pubkey_b64 -p 1111:1111 -p 8188:8188 -p 22:22"
        skipcheck=1
      else
        # REPO MODE — the bootstrap clones a provisioner repo (public OR private, via
        # GITLAB_TOKEN/GH_TOKEN) and runs its provision.sh. Two flavours:
        #   * aggregator (--workflow-name): provision.sh runs Vast's NATIVE provisioner on the
        #     named workflow's manifest, on the pre-baked vastai/comfy image (no bash engine).
        #     This is how a PRIVATE workflow repo is provisioned — cloned with the token, manifest
        #     run locally, so no public raw URL is needed.
        #   * legacy (no --workflow-name): our bash engine (PROVISION_LIB_URL) on vastai/base-image.
        [ -n "$repo" ] || { echo "vast-template-apply: --repo (or --manifest) is required." >&2; exit 1; }
        host="github.com"
        case "$repo" in
          gitlab:*) host="gitlab.com"; repo="''${repo#gitlab:}" ;;
          github:*) host="github.com"; repo="''${repo#github:}" ;;
        esac
        if [ -n "$wfname" ]; then
          [ -z "$image" ] && image="vastai/comfy"
          case "$image" in *:*) tag="''${image##*:}"; image="''${image%:*}" ;; *) tag="v0.28.0-cuda-12.9-py312" ;; esac
          [ -z "$disk" ] && disk="100"
          # No PROVISION_LIB_URL — the aggregator's provision.sh is self-contained (runs the
          # native provisioner). WORKFLOW_NAME selects which workflow's manifest to run.
          env_str="-e PROVISIONING_SCRIPT=${bootstrapUrl} -e PROVISION_HOST=$host -e PROVISION_REPO=$repo -e PROVISION_REF=$ref -e PROVISION_ENTRYPOINT=$entry -e WORKFLOW_NAME=$wfname -e PROVISIONER_FAILURE_ACTION=stop -e OPEN_BUTTON_PORT=1111 -e PORTAL_CONFIG=\"localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI\" -e SSH_PUBKEY_B64=$pubkey_b64 -p 1111:1111 -p 8188:8188 -p 22:22"
        else
          [ -z "$image" ] && image="vastai/base-image"
          case "$image" in *:*) tag="''${image##*:}"; image="''${image%:*}" ;; *) tag="cuda-12.6.3-auto" ;; esac
          [ -z "$disk" ] && disk="64"
          env_str="-e PROVISIONING_SCRIPT=${bootstrapUrl} -e PROVISION_LIB_URL=${libUrl} -e PROVISION_HOST=$host -e PROVISION_REPO=$repo -e PROVISION_REF=$ref -e PROVISION_ENTRYPOINT=$entry -e PROVISIONER_FAILURE_ACTION=stop -e PROVISION_MAX_SECONDS=5400 -e OPEN_BUTTON_PORT=1111 -e PORTAL_CONFIG=\"localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI\" -e SSH_PUBKEY_B64=$pubkey_b64 -p 1111:1111 -p 8188:8188 -p 22:22"
        fi
      fi

      body="$(jq -n \
        --arg name "$name" --arg image "$image" --arg tag "$tag" \
        --arg env "$env_str" --argjson disk "$disk" '
        { name: $name, image: $image, tag: $tag, env: $env, onstart: "",
          runtype: "args",
          recommended_disk_space: $disk, private: true }')"

      if [ -n "$dryrun" ]; then
        echo "vast-template-apply: DRY RUN — template '$name' body:"
        printf '%s\n' "$body" | jq .
        exit 0
      fi

      # Gate: the target repo must be a legitimate provisioner repo at this ref.
      if [ -z "$skipcheck" ]; then
        check_repo="github:$repo"
        [ "$host" = gitlab.com ] && check_repo="gitlab:$repo"
        if ! ${repo-check}/bin/vast-repo-check --repo "$check_repo" --ref "$ref"; then
          echo "vast-template-apply: repo legitimacy check failed — refusing to apply (--skip-check to override)." >&2
          exit 1
        fi
      fi

      # Reconcile by name among MY templates: replace = delete existing + create. The
      # update (PUT) endpoint is broken server-side (returns "Invalid Creator ID" even
      # with the CLI's exact auth), and delete+create yields the same idempotent
      # end-state (templates only affect NEW instances, so replacing is safe). The
      # unfiltered /template/ list is the global public catalog, so filter by creator_id.
      myid="$(curl -fsS -H "Authorization: Bearer $apikey" "${api}/users/current/" 2>/dev/null | jq -r '.id // empty')"
      if [ -z "$myid" ]; then
        echo "vast-template-apply: could not resolve the Vast user id for reconcile." >&2
        exit 1
      fi
      list="$(curl -fsS -G -H "Authorization: Bearer $apikey" "${api}/template/" \
               --data-urlencode 'select_cols=["*"]' \
               --data-urlencode "select_filters={\"creator_id\":{\"eq\":$myid}}" 2>/dev/null || true)"
      existing_id="$(printf '%s' "$list" | jq -r --arg n "$name" '(.templates // []) | map(select(.name==$n)) | (.[0].id // empty)')"

      action="created"
      if [ -n "$existing_id" ]; then
        del="$(curl -fsS -X DELETE "${api}/template/" -H "Authorization: Bearer $apikey" \
                -H "Content-Type: application/json" --data "{\"template_id\":$existing_id}" 2>/dev/null || true)"
        if [ "$(printf '%s' "$del" | jq -r '.success // false' 2>/dev/null)" != true ]; then
          echo "vast-template-apply: failed to delete existing template $existing_id for replace — $(printf '%s' "$del" | jq -rc '{msg,error}' 2>/dev/null)" >&2
          exit 1
        fi
        action="replaced"
      fi
      resp="$(printf '%s' "$body" | curl -fsS -X POST "${api}/template/" \
               -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"

      summary="$(printf '%s' "$resp" | jq -rc '{success, name: (.template.name // .name), id: (.template.id // .id), hash_id: (.template.hash_id // .hash_id)}' 2>/dev/null || true)"
      if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" = true ]; then
        echo "vast-template-apply: $action — $summary"
      else
        echo "vast-template-apply: FAILED — $(printf '%s' "$resp" | jq -rc '{success, msg, error}' 2>/dev/null || printf '%s' "$resp")" >&2
        exit 1
      fi
    '';
  };

  account-vars-set = writeShellApplication {
    name = "vast-account-vars-set";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      # Sync read-only tokens from the login Keychain (<NAME>) to Vast.ai
      # ACCOUNT-level environment variables (<NAME>), injected into every instance.
      # Default set: GITLAB_TOKEN HF_TOKEN CIVITAI_TOKEN GH_TOKEN; pass NAMEs to
      # override. Values are never printed (only their lengths, as proof).
      #
      # The Keychain entry and the Vast variable share ONE name. The former
      # VAST_<NAME> convention is gone: it duplicated every credential just to
      # mark intent, and the copies drifted out of existence (all four were
      # missing by 2026-09-06, so this app silently synced nothing). Intent is
      # now carried by the ARGUMENT LIST, which is the thing that actually
      # decides what leaves the machine.
      #
      # So: anything you name here is pushed to every instance and is visible to
      # the host operator. Name a token deliberately; there is no prefix left to
      # catch a mistake. DOCKERHUB_TOKEN and VAST_API_KEY are Mac-side only and
      # must never be passed.
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s VAST_API_KEY -w 2>/dev/null || true)"
      if [ -z "$apikey" ]; then
        echo "vast-account-vars-set: VAST_API_KEY not in the login Keychain." >&2
        exit 1
      fi

      names=("$@")
      if [ "''${#names[@]}" -eq 0 ]; then
        names=(GITLAB_TOKEN HF_TOKEN CIVITAI_TOKEN GH_TOKEN)
      fi

      rc=0
      for name in "''${names[@]}"; do
        val="$("$security" find-generic-password -a "$account" -s "$name" -w 2>/dev/null || true)"
        if [ -z "$val" ]; then
          echo "$name: SKIP (Keychain $name missing — 'secret set $name <value>')"; rc=1; continue
        fi
        body="$(val="$val" jq -n --arg k "$name" '{key: $k, value: env.val}')"
        resp="$(printf '%s' "$body" | curl -fsS -X POST "${api}/secrets/" \
                 -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
        if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" != true ]; then
          resp="$(printf '%s' "$body" | curl -fsS -X PUT "${api}/secrets/" \
                   -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
        fi
        if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" = true ]; then
          echo "$name: set on Vast (value length ''${#val})"
        else
          echo "$name: FAILED ($(printf '%s' "$resp" | jq -rc '{msg, error}' 2>/dev/null || true))"; rc=1
        fi
        val=""
      done
      exit "$rc"
    '';
  };

  # Register the operator's SSH public key on the Vast account (idempotent). The
  # reproducible analog of a manual `vastai create ssh-key` — needed after a key
  # rotation / new machine / account reset. CAVEAT: Vast's auto-injection of account
  # SSH keys into instances is runtype=ssh ONLY; our runtype=args templates instead
  # plant the operator key via SSH_PUBKEY_B64 (provision.sh starts sshd). So this app
  # is for account registration, NOT the args SSH path.
  ssh-key-set = writeShellApplication {
    name = "vast-ssh-key-set";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s VAST_API_KEY -w 2>/dev/null || true)"
      if [ -z "$apikey" ]; then
        echo "vast-ssh-key-set: VAST_API_KEY not in the login Keychain." >&2
        exit 1
      fi

      keyfile="$HOME/.ssh/id_ed25519.pub"
      while [ $# -gt 0 ]; do
        case "$1" in
          --key) keyfile="''${2:?}"; shift 2 ;;
          -h | --help) echo "usage: vast-ssh-key-set [--key PATH.pub]  (default ~/.ssh/id_ed25519.pub)"; exit 0 ;;
          *) echo "vast-ssh-key-set: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -f "$keyfile" ] || { echo "vast-ssh-key-set: no public key at $keyfile" >&2; exit 1; }

      pub="$(cat "$keyfile")"
      body="$(cut -d' ' -f2 < "$keyfile")"   # key material, ignoring type + comment

      list="$(curl -fsS -H "Authorization: Bearer $apikey" "${api}/ssh/" 2>/dev/null || true)"
      if printf '%s' "$list" | jq -r '(if type=="array" then . else (.ssh_keys // .keys // []) end)[] | (.public_key // .ssh_key // .)' 2>/dev/null | grep -qF "$body"; then
        echo "vast-ssh-key-set: already registered ($(/usr/bin/ssh-keygen -lf "$keyfile" 2>/dev/null | awk '{print $2}'))."
        exit 0
      fi

      resp="$(jq -n --arg k "$pub" '{ssh_key: $k}' | curl -fsS -X POST "${api}/ssh/" \
               -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
      if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" = true ]; then
        echo "vast-ssh-key-set: registered $keyfile on the Vast account."
      else
        echo "vast-ssh-key-set: FAILED — $(printf '%s' "$resp" | jq -rc '{success, msg, error}' 2>/dev/null || printf '%s' "$resp")" >&2
        exit 1
      fi
    '';
  };

  # Scaffold a new provisioner repo from the generic templates/provisioner, on either
  # forge, public or private. The check is structural (not provenance), so this is a
  # convenience — a valid provisioner repo is just one containing provision.sh + the
  # marker. --template also flips is_template (GitHub only).
  init-repo = writeShellApplication {
    name = "vast-init-repo";
    runtimeInputs = [
      gh
      glab
      git
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"

      repo=""
      vis="--private"
      desc="Vast.ai provisioner repo (scaffolded from provisioner-template)"
      astemplate=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo) repo="''${2:?}"; shift 2 ;;
          --private) vis="--private"; shift ;;
          --public) vis="--public"; shift ;;
          --desc) desc="''${2:?}"; shift 2 ;;
          --template) astemplate=1; shift ;;
          -h | --help)
            echo "usage: vast-init-repo --repo [github:|gitlab:]owner/name [--public|--private] [--desc TEXT] [--template]"
            exit 0 ;;
          *) echo "vast-init-repo: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -n "$repo" ] || { echo "vast-init-repo: --repo is required." >&2; exit 1; }

      host="github.com"
      case "$repo" in
        gitlab:*) host="gitlab.com"; repo="''${repo#gitlab:}" ;;
        github:*) host="github.com"; repo="''${repo#github:}" ;;
      esac

      # Seed a temp git repo with the baked scaffold files.
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      cp ${./templates/provisioner/provision.sh} "$tmp/provision.sh"
      cp ${./templates/provisioner/provision-lib.sh} "$tmp/provision-lib.sh"
      cp ${./templates/provisioner/.provisioner-template.json} "$tmp/.provisioner-template.json"
      cp ${./templates/provisioner/README.md} "$tmp/README.md"
      chmod +x "$tmp/provision.sh" "$tmp/provision-lib.sh"
      git -C "$tmp" init -q -b main
      git -C "$tmp" add -A
      git -C "$tmp" -c user.email="vast-init-repo@localhost" -c user.name="$account" \
        commit -q -m "Initialize from provisioner-template"

      case "$host" in
        github.com)
          ghtok="$("$security" find-generic-password -a "$account" -s GH_TOKEN -w 2>/dev/null || true)"
          [ -n "$ghtok" ] || { echo "vast-init-repo: GH_TOKEN not in Keychain." >&2; exit 1; }
          export GH_TOKEN="$ghtok"
          echo "vast-init-repo: creating github.com/$repo ($vis)"
          gh repo create "$repo" "$vis" --description "$desc"
          git -C "$tmp" remote add origin "https://github.com/$repo.git"
          # shellcheck disable=SC2016
          TOK="$ghtok" git -C "$tmp" -c credential.helper='!f(){ echo username=oauth2; echo "password=$TOK"; };f' \
            push -u origin main
          if [ -n "$astemplate" ]; then
            gh api -X PATCH "repos/$repo" -f is_template=true >/dev/null && echo "vast-init-repo: marked as template repository."
          fi
          echo "vast-init-repo: done -> https://github.com/$repo"
          ;;
        gitlab.com)
          gltok="$("$security" find-generic-password -a "$account" -s GITLAB_TOKEN -w 2>/dev/null || true)"
          [ -n "$gltok" ] || { echo "vast-init-repo: GITLAB_TOKEN not in Keychain." >&2; exit 1; }
          export GITLAB_TOKEN="$gltok"
          gvis="private"
          [ "$vis" = "--public" ] && gvis="public"
          echo "vast-init-repo: creating gitlab.com/$repo ($gvis)"
          glab repo create "$repo" "--$gvis" --description "$desc" >/dev/null
          git -C "$tmp" remote add origin "https://gitlab.com/$repo.git"
          # shellcheck disable=SC2016
          TOK="$gltok" git -C "$tmp" -c credential.helper='!f(){ echo username=oauth2; echo "password=$TOK"; };f' \
            push -u origin main
          [ -n "$astemplate" ] && echo "vast-init-repo: NOTE — GitLab has no per-repo template flag; use group custom project templates."
          echo "vast-init-repo: done -> https://gitlab.com/$repo"
          ;;
      esac
    '';
  };

  # Rent a Vast instance from one of our templates WITH authenticated Docker Hub
  # registry login. Vast has NO account-level registry store and templates provably
  # cannot carry credentials (the /template/ body keeps only docker_login_repo, not
  # user/pass — verified against vast-python), so the Docker Hub PAT can
  # ONLY ride the per-instance create call's `image_login`. This app is that single
  # honest home: it reads DOCKERHUB_TOKEN from the Keychain and userName as the
  # Docker Hub username, and injects `-u <user> -p <pat> docker.io` so the base-image
  # pull uses OUR account rate budget instead of the shared-per-IP anonymous limit
  # (whose exhaustion stalls the pull — layers stuck "Waiting", pull restarting).
  rent = writeShellApplication {
    name = "vast-rent";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s VAST_API_KEY -w 2>/dev/null || true)"
      [ -n "$apikey" ] || { echo "vast-rent: VAST_API_KEY not in the login Keychain." >&2; exit 1; }
      # Docker Hub PAT from the Keychain (optional but recommended); username = flake identity.
      dhtoken="$("$security" find-generic-password -a "$account" -s DOCKERHUB_TOKEN -w 2>/dev/null || true)"
      dhuser="${userName}"

      tname=""; thash=""; offer=""; gpus="RTX 4090,RTX 5090"; disk="64"; maxprice=""; dryrun=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --template-name) tname="''${2:?}"; shift 2 ;;
          --template-hash) thash="''${2:?}"; shift 2 ;;
          --offer) offer="''${2:?}"; shift 2 ;;
          --gpu) gpus="''${2:?}"; shift 2 ;;
          --disk) disk="''${2:?}"; shift 2 ;;
          --max-price) maxprice="''${2:?}"; shift 2 ;;
          --dry-run) dryrun=1; shift ;;
          -h | --help)
            echo "usage: vast-rent (--template-name NAME | --template-hash HASH) \\"
            echo "         [--offer ID] [--gpu \"RTX 4090,RTX 5090\"] [--disk GB] [--max-price DPH] [--dry-run]"
            echo "Injects authenticated Docker Hub image_login (user=${userName}) from DOCKERHUB_TOKEN to beat pull rate limits."
            exit 0 ;;
          *) echo "vast-rent: unknown argument: $1" >&2; exit 1 ;;
        esac
      done

      # Resolve the template hash by name among MY templates (filter by creator_id).
      if [ -z "$thash" ]; then
        [ -n "$tname" ] || { echo "vast-rent: --template-name or --template-hash is required." >&2; exit 1; }
        myid="$(curl -fsS -H "Authorization: Bearer $apikey" "${api}/users/current/" 2>/dev/null | jq -r '.id // empty')"
        [ -n "$myid" ] || { echo "vast-rent: could not resolve the Vast user id." >&2; exit 1; }
        list="$(curl -fsS -G -H "Authorization: Bearer $apikey" "${api}/template/" \
                 --data-urlencode 'select_cols=["*"]' \
                 --data-urlencode "select_filters={\"creator_id\":{\"eq\":$myid}}" 2>/dev/null || true)"
        thash="$(printf '%s' "$list" | jq -r --arg n "$tname" '(.templates // []) | map(select(.name==$n)) | (.[0].hash_id // empty)')"
        [ -n "$thash" ] || { echo "vast-rent: no template named '$tname' on this account." >&2; exit 1; }
      fi

      # Auto-select an offer if none given: verified (secure cloud), rentable, matching
      # GPU, enough disk + headroom, decent inet, high reliability, cheapest.
      if [ -z "$offer" ]; then
        gpujson="$(printf '%s' "$gpus" | jq -R 'split(",") | map(gsub("^ +| +$";""))')"
        q="$(jq -n --argjson gpu "$gpujson" --argjson disk "$disk" \
             '{q:{verified:{eq:true},rentable:{eq:true},gpu_name:{in:$gpu},num_gpus:{eq:1},
                  disk_space:{gte:($disk+6)},inet_down:{gte:1000},order:[["dph_total","asc"]],type:"on-demand"}}')"
        offers="$(printf '%s' "$q" | curl -fsS -X PUT "${api}/search/asks/" \
                   -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
        offer="$(printf '%s' "$offers" | jq -r --arg mp "$maxprice" '
          (.offers // []) | map(select(.reliability2 >= 0.99))
          | (if $mp != "" then map(select(.dph_total <= ($mp | tonumber))) else . end)
          | sort_by(.dph_total) | (.[0].id // empty)')"
        [ -n "$offer" ] || { echo "vast-rent: no matching offer (gpu=$gpus disk>=$disk)." >&2; exit 1; }
        echo "vast-rent: selected offer $(printf '%s' "$offers" | jq -rc --argjson id "$offer" '(.offers // []) | map(select(.id==$id)) | .[0] | {id,gpu_name,dph_total,reliability2,inet_down,geolocation}')"
      fi

      # image_login rides ONLY the create call (no account/template cred store on Vast).
      # Passed to jq via env ($ENV.LOGIN) and to curl via stdin, so the token never
      # appears in any process's argv.
      login=""
      if [ -n "$dhtoken" ]; then
        login="-u $dhuser -p $dhtoken docker.io"
        echo "vast-rent: authenticated Docker Hub pull as '$dhuser'."
      else
        echo "vast-rent: WARN — no DOCKERHUB_TOKEN in the Keychain; anonymous pull may hit Docker Hub rate limits." >&2
      fi
      body="$(LOGIN="$login" jq -n --arg h "$thash" --argjson disk "$disk" \
        '{template_hash_id: $h, disk: $disk} + (if ($ENV.LOGIN | length) > 0 then {image_login: $ENV.LOGIN} else {} end)')"

      if [ -n "$dryrun" ]; then
        echo "vast-rent: DRY RUN — would PUT ${api}/asks/$offer/ with body (login redacted):"
        printf '%s\n' "$body" | jq '(.image_login) |= (if . then "-u '"$dhuser"' -p <redacted> docker.io" else . end)'
        exit 0
      fi

      resp="$(printf '%s' "$body" | curl -fsS -X PUT "${api}/asks/$offer/" \
               -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
      if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" = true ]; then
        iid="$(printf '%s' "$resp" | jq -r '.new_contract // empty')"
        echo "vast-rent: rented instance $iid (template $thash, offer $offer). Watch the Vast console Logs for the PROVISION-OUTCOME line."
      else
        echo "vast-rent: FAILED — $(printf '%s' "$resp" | jq -rc '{success, msg, error}' 2>/dev/null || printf '%s' "$resp")" >&2
        exit 1
      fi
    '';
  };

  # Lint the committed instance-side scripts at `nix flake check` (served as raw
  # files / fetched at boot, so they can't be writeShellApplications).
  scripts-lint =
    runCommand "vast-scripts-lint"
      {
        nativeBuildInputs = [ shellcheck ];
      }
      ''
        shellcheck \
          ${./vast-bootstrap.sh} \
          ${./templates/provisioner/provision-lib.sh} \
          ${./templates/provisioner/provision.sh}
        touch "$out"
      '';
in
{
  inherit
    template-apply
    repo-check
    account-vars-set
    ssh-key-set
    init-repo
    rent
    scripts-lint
    ;
}
