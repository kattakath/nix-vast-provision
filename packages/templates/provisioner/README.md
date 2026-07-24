# provisioner-template

Canonical **generic** template for Vast.ai provisioner-script repos consumed by the
flake-based Vast.ai template provisioner
([`nix-vast-provision`](https://github.com/ismailkattakath/nix-vast-provision)).
Create a new provisioner repo **from this template** (GitHub "Use this template" /
GitLab custom project template — see `vast-init-repo`); it inherits the constant
`provision.sh` entrypoint and the marker that `vast-repo-check` validates.

It is **stack-agnostic** — `nix-vast-provision`'s bootstrap clones your repo and
runs `provision.sh`, making no assumption about what you provision. Build a
stack-specific template (e.g. a ComfyUI one, with its own engine/config schema)
*from* this generic one; those specifics live in your repos, never in
`nix-vast-provision`.

## Files

- **`provision.sh`** — the constant entrypoint. Put ALL your stack logic here (or have
  it fetch/source whatever you like). Runs on first boot with the cloned repo as CWD;
  Vast account env vars (`HF_TOKEN`, `CIVITAI_TOKEN`, `GITLAB_TOKEN`, `GH_TOKEN`) are
  available. See its header.
- **`provision-lib.sh`** — an optional, self-contained shared engine (model/node/
  workflow fetch helpers for a ComfyUI-style stack, with a strict funneled
  success/failure verdict). `provision.sh` sources it via `$PROVISION_LIB`, which
  `vast-template-apply` points at this repo's own pinned copy. Not required — a
  `provision.sh` can be fully self-contained instead.
- **`.provisioner-template.json`** — the marker `vast-repo-check` validates (schema
  version + required files) before `vast-template-apply` will provision. Keep it.

## How it runs

Vast template `PROVISIONING_SCRIPT` → `nix-vast-provision`'s bootstrap clones this
repo (private repos authenticate with a `GITLAB_TOKEN`/`GH_TOKEN` Vast account var)
→ runs `provision.sh`. See the root README's "How it works" section.
