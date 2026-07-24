# nix-vast-provision

[![CI](https://github.com/ismailkattakath/nix-vast-provision/actions/workflows/ci.yml/badge.svg)](https://github.com/ismailkattakath/nix-vast-provision/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Built with Nix](https://img.shields.io/badge/built%20with-Nix-5277C3.svg?logo=nixos&logoColor=white)](https://nixos.org)

A declarative, all-Nix toolkit for provisioning [Vast.ai](https://vast.ai) GPU
templates from `vastai/base-image`: reconcile a template by name, gate it on a
structural legitimacy check of your provisioner repo, sync read-only tokens to
Vast's account-level secret store, register your SSH key, and scaffold new
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
  [`nix-keychain-secrets`](https://github.com/ismailkattakath/nix-keychain-secrets)
  for a `secret set KEY VALUE` CLI + every-shell loader that pairs well with it).
  Register these by convention (name is what each app looks up; `VAST_` variants
  are read-only tokens synced to Vast, the bare names are the Vast API key itself):
  - `VAST_API_KEY` — your Vast.ai API key (required by every app except
    `vast-repo-check`/`vast-init-repo`).
  - `VAST_GITLAB_TOKEN`, `VAST_HF_TOKEN`, `VAST_CIVITAI_TOKEN`, `VAST_GH_TOKEN` —
    read-only tokens `vast-account-vars-set` pushes to Vast as `GITLAB_TOKEN`,
    `HF_TOKEN`, `CIVITAI_TOKEN`, `GH_TOKEN` (its default set; pass other names as
    args to sync different ones).
  - `GH_TOKEN` / `GITLAB_TOKEN` — used locally by `vast-repo-check` (to read a
    private repo's marker file) and `vast-init-repo` (to create + push a new repo).
- **`gh`/`git`** (GitHub) and/or **`glab`/`git`** (GitLab) on `PATH` if you use
  `vast-init-repo` — both are pulled in automatically as `runtimeInputs`, no
  separate install needed when run via `nix run`.
- `~/.ssh/id_ed25519.pub` — `vast-template-apply` and `vast-ssh-key-set` inject/
  register it so instances are reachable over SSH.

## Install

```nix
{
  inputs.vast-provision.url = "github:ismailkattakath/nix-vast-provision";
}
```

Then either `nix run github:ismailkattakath/nix-vast-provision#<app>` directly, or
reference `vast-provision.packages.${system}.<name>` / `.apps.${system}.<name>`
from your own flake (e.g. as a `packages`/`apps` passthrough — see "Used in
production" below for a real example).

Run standalone from a clone of this repo:

```sh
git clone https://github.com/ismailkattakath/nix-vast-provision.git
cd nix-vast-provision
nix run .#vast-template-apply -- --help
```

## Usage

### `vast-template-apply`

Create or **replace** (reconcile by name — Vast's template `PUT` is broken
server-side, so replace is delete-then-create) a Vast.ai template whose instances
boot `vastai/base-image`, fetch the public
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

`--repo` accepts `github:owner/repo` or `gitlab:owner/repo` (defaults to GitHub).
By default the target repo is gated on `vast-repo-check` before the template is
written; pass `--skip-check` to bypass. `--dry-run` prints the template body without
calling the API.

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

Sync read-only tokens from the login Keychain (`VAST_<NAME>`) to Vast.ai
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

## Used in production

See it wired into a real fleet in
**[kattakath/nix-config](https://github.com/kattakath/nix-config)** —
[`packages/vast-provision.nix`](https://github.com/kattakath/nix-config/blob/main/packages/vast-provision.nix)
is that repo's pre-extraction copy of this toolkit, and
[`docs/vastai-template-provisioning.md`](https://github.com/kattakath/nix-config/blob/main/docs/vastai-template-provisioning.md)
documents the design this flake implements.

## License

MIT © Ismail Kattakath
