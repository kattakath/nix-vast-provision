#!/usr/bin/env bash
# provision.sh — the THIN, constant entrypoint every ComfyUI provisioner repo exposes.
# Runs once on first boot: vast-bootstrap.sh fetches the pinned shared engine
# (provision-lib.sh) and clones this repo, then exec's this file. This file owns NO
# provisioning LOGIC — it only sources the engine, declares WHAT this stack needs, and
# calls comfyui_provision. The engine derives a true success/failure verdict and funnels
# every failure (see PROVISION-OUTCOME + /workspace/provision-status.json). There is no
# `|| true`, no swallowed failure, and no unconditional "complete" line — by construction.
#
# The MODEL_MAP/NODES/ALIAS_MAP/WORKFLOW_MAP/REQUIRE_TOKENS arrays are consumed by the
# sourced engine, which shellcheck can't see across the `source`; hence SC2034 off.
# shellcheck disable=SC2034
set -Eeuo pipefail

# The engine, pinned + fetched by the bootstrap (fallback to a repo-local copy for testing).
# shellcheck source=/dev/null
. "${PROVISION_LIB:-./provision-lib.sh}"

# ── WHAT THIS STACK NEEDS ──────────────────────────────────────────────────
# MODEL_MAP entry:  dest|host|id|required|sha256
#   host=hf      id=<org/repo>/resolve/<rev>/<file>   (Bearer HF_TOKEN)
#   host=civitai id=<modelVersionId>                  (curl, ?token=CIVITAI_TOKEN)
#   host=url     id=<full-url>
#   required models MUST carry a sha256 (enforced); optional may omit it.
MODEL_MAP=(
  # "checkpoints/base.safetensors|hf|org/repo/resolve/main/base.safetensors|1|<sha256>"
  # "loras/face.safetensors|civitai|123456|1|<sha256>"
)

# NODES entry: url|commit|dir|extra|required   (commit pins reproducibility)
NODES=(
  # "https://github.com/ltdrdata/ComfyUI-Manager||||1"
)

# ALIAS_MAP entry: legacy:canon  (symlink a legacy node dir name to its canonical clone)
ALIAS_MAP=()

# WORKFLOW_MAP entry: fname|source|required   (source empty => repo comfyui/<fname>)
WORKFLOW_MAP=(
  # "MyWorkflow.json||1"
)

# Extra tokens used by nodes/workflow/pip that MODEL_MAP can't reveal (hf civitai gh …).
REQUIRE_TOKENS=()

comfyui_provision
