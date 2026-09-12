> [!IMPORTANT]
> ## Archived 2026-09-12 — this flake now lives inside `kattakath/nix-config`
>
> The code moved to **`modules/features/vast-provision/`** in
> [kattakath/nix-config](https://github.com/kattakath/nix-config), as a *capsule*: a
> directory that may not reach outside itself, enforced by the repo's `ast-grep` gate rather
> than by convention.
>
> **Why:** maintaining seven satellite flakes cost seven CI pipelines, seven merge queues and a
> lock-bump dance for every cross-cutting change — for repos with 2 GitHub stars between them.
> The rationale, the four competing architectures that were scored, the adversarial review that
> found three blocking defects, and an honest list of what the collapse gives up are all in
> [`docs/monoflake-capsule-adr.md`](https://github.com/kattakath/nix-config/blob/main/docs/monoflake-capsule-adr.md).
>
> **This repository is read-only.** Its history is preserved here and is the only place it
> exists — the absorption was a plain copy, not a `git subtree`, so `git blame` in nix-config
> stops at the collapse commit and continues here.

# nix-vast-provision

[![CI](https://github.com/kattakath/nix-vast-provision/actions/workflows/ci.yml/badge.svg)](https://github.com/kattakath/nix-vast-provision/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Built with Nix](https://img.shields.io/badge/built%20with-Nix-5277C3.svg?logo=nixos&logoColor=white)](https://nixos.org)

A declarative, all-Nix toolkit for provisioning [Vast.ai](https://vast.ai) GPU
templates (`vastai/base-image` or `vastai/comfy`): reconcile a template by name,
gate it on a structural legitimacy check of your provisioner repo, sync read-only
tokens to Vast's account-level secret store, register your SSH key, and scaffold new
provisioner repos from a generic template — all as macOS `writeShellApplication`s
you can `nix run` directly or wire into your own flake. No custom Docker image, no
registry auth, and secrets never touch the template: Vast.ai's
[account-level environment variables](https://docs.vast.ai/instances/docker-environment#user-account-variables)
are the sole delivery mechanism, so a template stays inspectable (or even public)
while your GitLab/HuggingFace/Civitai tokens stay out of it entirely.

## Prerequisites

- **macOS** (Apple Silicon) — every CLI shells out to `/usr/bin/security` (the
  login Keychain); there's no Linux path.
- **Nix** with flakes enabled (`experimental-features = nix-command flakes`).
- **A [Vast.ai](https://vast.ai) account** with an API key.
- **A secret store** — the login Keychain via `/usr/bin/security`, or any tool that
  can populate it (this repo doesn't ship one; see
  [`nix-keychain-secrets`](https://github.com/kattakath/nix-keychain-secrets)
  for a `secret set KEY VALUE` CLI + every-shell loader that pairs well with it).
  Register these by convention — **the Keychain entry and the Vast variable share
  one name**; there are no `VAST_`-prefixed duplicates:
  - `VAST_API_KEY` — your Vast.ai API key (required by every app except
    `vast-repo-check`/`vast-init-repo`). Mac-side only; never synced.
  - `GITLAB_TOKEN`, `HF_TOKEN`, `CIVITAI_API_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN` —
    the entries backing `vast-account-vars-set`'s default set. The **Vast variable
    names** it pushes are `GITLAB_TOKEN`, `HF_TOKEN`, `CIVITAI_TOKEN`, `GH_TOKEN` —
    those are fixed, because the container reads them (`vast-bootstrap.sh` clone
    auth, `provision-lib.sh` civitai/HF fetches). Two are read from a
    differently-spelled entry:

    | Vast variable (fixed) | Keychain entry read |
    |---|---|
    | `GITLAB_TOKEN` | `GITLAB_TOKEN` |
    | `HF_TOKEN` | `HF_TOKEN` |
    | `CIVITAI_TOKEN` | `CIVITAI_API_TOKEN` |
    | `GH_TOKEN` | `GITHUB_PERSONAL_ACCESS_TOKEN` |

    `GITLAB_TOKEN` and `GITHUB_PERSONAL_ACCESS_TOKEN` are *also* what
    `vast-repo-check` (read a private repo's marker file) and `vast-init-repo`
    (create + push a new repo) use locally — one entry, both uses.
  - `DOCKERHUB_TOKEN` — a Docker Hub personal access token, used **only** by
    `vast-rent` at instance-create time (`image_login`) to beat anonymous pull
    rate limits. Mac-side, rent-time only — never pass it to
    `vast-account-vars-set`.

  > **The prefix is gone, and with it the training wheel.** `VAST_<NAME>` used to
  > mark "safe to sync"; it duplicated *every* credential to encode intent, and the
  > duplicates rotted — by 2026-09-06 all four were missing and this app synced
  > nothing while reporting only SKIPs. The alias table above is not a return to
  > that: it reuses the general token for the two whose canonical entry is spelled
  > differently, rather than demanding a second copy of anything.
  >
  > Intent now lives in the argument list. **Whatever you name is pushed to every
  > instance and is readable by the host operator, so scope those tokens read-only.**
- **`gh`/`git`** (GitHub) and/or **`glab`/`git`** (GitLab) on `PATH` if you use
  `vast-init-repo` — both are pulled in automatically as `runtimeInputs`, no
  separate install needed when run via `nix run`.
- `~/.ssh/id_ed25519.pub` — `vast-template-apply` and `vast-ssh-key-set` inject/
  register it so instances are reachable over SSH.

## Install

```nix
{
  inputs.vast-provision.url = "github:kattakath/nix-vast-provision";
}
```

Then either `nix run github:kattakath/nix-vast-provision#<app>` directly, or
reference `vast-provision.packages.${system}.<name>` / `.apps.${system}.<name>`
from your own flake (e.g. as a `packages`/`apps` passthrough — see "Used in
production" below for a real example).

Run standalone from a clone of this repo:

```sh
git clone https://github.com/kattakath/nix-vast-provision.git
cd nix-vast-provision
nix run .#vast-template-apply -- --help
```

## Usage

### `vast-template-apply`

Create or **replace** (reconcile by name — Vast's template `PUT` is broken
server-side, so replace is delete-then-create) a Vast.ai template. Three modes,
selected explicitly by flags — there's no auto-detection:

**Legacy / repo mode** — instances boot `vastai/base-image`, fetch the public
[`vast-bootstrap.sh`](./packages/vast-bootstrap.sh) via `PROVISIONING_SCRIPT`, clone
your provisioner repo (public or private — token from an account variable), and run
its `provision.sh`.

```sh
nix run .#vast-template-apply -- \
  --template-name my-stack \
  --repo github:you/my-provisioner-repo \
  [--ref main] [--entrypoint provision.sh] [--image vastai/base-image:cuda-12.6.3-auto] \
  [--disk 64] [--dry-run] [--skip-check]
```

**Aggregator mode** (`--repo` + `--workflow-name`) — clones a **private**
aggregator repo whose own self-contained `provision.sh` runs Vast's **native**
`PROVISIONING_MANIFEST` provisioner locally (no bash engine at all), on the
pre-baked `vastai/comfy` image, against the named workflow's manifest:

```sh
nix run .#vast-template-apply -- \
  --template-name my-comfy-stack \
  --repo gitlab:you/comfyui-workflows \
  --workflow-name my-workflow
```

First-run caveat: aggregator mode does **not** auto-set `--skip-check` (unlike
manifest mode below), so `vast-repo-check` runs against your private aggregator
repo and may fail until it's a valid provisioner repo in its own right — pass
`--skip-check` on first apply if needed.

**Manifest mode** (`--manifest` + `--workflow`) — no repo clone, no bash engine:
Vast's native provisioner runs directly against a rev-pinned manifest + workflow
JSON committed in **your own repo**, not this one. Point `orgName`/`repoName`/`rev`
at your repo via `callPackage` so the generated URLs resolve there:

```nix
callPackage ./packages/vast-provision.nix {
  orgName = "you"; repoName = "your-repo"; rev = "<sha-or-main>";
}
```

```sh
nix run .#vast-template-apply -- \
  --template-name my-comfy-stack \
  --manifest path/to/your/provisioning.yaml \
  --workflow path/to/your/workflow.json
```

`--repo` accepts `github:owner/repo` or `gitlab:owner/repo` (defaults to GitHub).
Repo-mode and aggregator-mode targets are gated on `vast-repo-check` before the
template is written (pass `--skip-check` to bypass); manifest mode has no repo to
check, so it sets `--skip-check` automatically. `--dry-run` prints the template
body without calling the API, for any mode.

### `vast-repo-check`

Validate — **structurally**, not by forge provenance (GitHub records
`template_repository`; GitLab records nothing, so this works identically on both) —
that a repo is a legitimate provisioner repo: it fetches only
`.provisioner-template.json` (schema version + `required_files`) and confirms each
required file exists, via each forge's single-file API. No clone.

```sh
nix run .#vast-repo-check -- --repo github:you/my-provisioner-repo [--ref main]
```

### `vast-account-vars-set`

Sync read-only tokens from the login Keychain (`<NAME>`) to Vast.ai
**account-level** environment variables (`<NAME>`), which Vast injects into every
instance you launch regardless of template.

```sh
nix run .#vast-account-vars-set                       # default set: GITLAB_TOKEN HF_TOKEN CIVITAI_TOKEN GH_TOKEN
nix run .#vast-account-vars-set -- GITLAB_TOKEN HF_TOKEN   # or name your own
```

### `vast-ssh-key-set`

Register `~/.ssh/id_ed25519.pub` (or `--key PATH.pub`) on the Vast account,
idempotently. Note: this covers Vast's own account-key auto-injection
(`runtype=ssh` templates only); the `runtype=args` templates `vast-template-apply`
generates instead inject the key directly via `SSH_PUBKEY_B64`, so this app is for
account bookkeeping, not a prerequisite for `vast-template-apply` to work.

```sh
nix run .#vast-ssh-key-set [-- --key ~/.ssh/other_key.pub]
```

### `vast-init-repo`

Scaffold a new provisioner repo from [`packages/templates/provisioner/`](./packages/templates/provisioner)
(the constant `provision.sh` entrypoint + `.provisioner-template.json` marker +
`provision-lib.sh` shared engine), on GitHub or GitLab, public or private.

```sh
nix run .#vast-init-repo -- --repo github:you/my-provisioner-repo [--public|--private] [--desc "..."] [--template]
```

`--template` additionally marks the new repo as a GitHub template repository
(`is_template`); GitLab has no per-repo equivalent — use group custom project
templates instead.

### `vast-rent`

Rent a live, **BILLED** GPU instance from one of your templates. Resolves the
template by name (or `--template-hash` directly) among your own templates,
auto-selects a rentable on-demand offer if you don't pass `--offer` (verified,
matching GPU, enough disk, reliability ≥0.99, decent inet, cheapest first), and —
if `DOCKERHUB_TOKEN` is in the Keychain — injects an authenticated Docker Hub
`image_login` at instance-create time, so the image pull uses your account's rate
budget instead of the shared anonymous-per-IP limit.

```sh
nix run .#vast-rent -- \
  --template-name my-stack \
  [--offer ID] [--gpu "RTX 4090,RTX 5090"] [--disk 64] [--max-price 0.50] [--dry-run]
```

**This is the one command in this toolkit that spends real money.** Always
`--dry-run` first.

## How it works

1. **`PROVISIONING_SCRIPT` is the sole customization path** on `vastai/base-image`
   — a URL the base image fetches anonymously at first boot, after Caddy + the
   Instance Portal are already up. `vast-template-apply` points it at this repo's
   own [`packages/vast-bootstrap.sh`](./packages/vast-bootstrap.sh), pinned to a
   specific commit (`orgName`/`repoName`/`rev` in `flake.nix` — defaults to this
   repo itself; override if you forked it).
2. **The bootstrap fetches a shared engine** ([`provision-lib.sh`](./packages/templates/provisioner/provision-lib.sh),
   same pinned rev), then clones your **provisioner repo** — public or private,
   authenticated with a token read from the container's environment, never
   embedded in the script — and execs its `provision.sh`. Your `provision.sh` is
   free to be fully self-contained instead of sourcing the shared engine.
3. **Secrets never touch the template.** They live in Vast's account-level
   environment variables (`vast-account-vars-set`), injected into every instance
   you launch — the template blob itself carries only non-secret config
   (`PROVISION_REPO`, `PROVISION_REF`, ...) and could even be made public.
4. **Legitimacy, not trust.** `vast-repo-check` is deliberately *structural*
   (marker file + required files) rather than provenance-based, since GitHub and
   GitLab expose template ancestry asymmetrically — this makes the check work
   identically on both forges.
5. **Two provisioning engines, not just flag variations.** Legacy/repo mode uses
   this toolkit's own bash bootstrap engine on `vastai/base-image`. Aggregator and
   manifest modes instead hand off entirely to Vast's own **native**
   `PROVISIONING_MANIFEST` provisioner on the pre-baked `vastai/comfy` image — no
   bootstrap, no shared engine script, just a manifest (either fetched from a
   rev-pinned URL, or run locally by a private aggregator repo's own
   `provision.sh`). Pick whichever engine fits your stack.

## Used in production

See it wired into a real fleet in
**[kattakath/nix-config](https://github.com/kattakath/nix-config)**, which consumes
this repo as a flake input (`vast-provision.url = "github:kattakath/nix-vast-provision"`)
and re-exports its CLIs as fleet apps, and whose
[`docs/vastai-template-provisioning.md`](https://github.com/kattakath/nix-config/blob/main/docs/vastai-template-provisioning.md)
documents the design this flake implements.

## License

MIT © Ismail Kattakath
