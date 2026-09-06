# Contributing

A small, focused, macOS-only flake — contributions that keep it that way are
the most welcome.

## Dev loop

```sh
nix flake check -L    # build every CLI (shellcheck) + scripts-lint + treefmt
nix fmt               # treefmt: nixfmt + deadnix + statix (checks.treefmt gates it)
nix build .#packages.aarch64-darwin.vast-template-apply
```

## Guidelines

- The CLIs stay POSIX-ish shell in `writeShellApplication` (shellcheck-clean
  under `set -euo pipefail`).
- No secret **values** in code, ever — the Keychain is the only store; git/Nix
  hold neither. `VAST_*` **names** are just a documented convention, fine to
  reference.
- `packages/vast-bootstrap.sh` and `packages/templates/provisioner/*.sh` are
  fetched raw / cloned at Vast instance-boot time, so they stay plain shell
  scripts (not `writeShellApplication`) — `scripts-lint` shellchecks them at
  `nix flake check` instead.
- Keep `orgName`/`repoName`/`rev` as the only place a fork's GitHub coordinates
  need to change (`flake.nix` + `packages/vast-provision.nix`'s function args)
  — never hardcode a raw-URL elsewhere. This includes manifest mode's `rawBase`,
  which is derived from the same three args.
- `DOCKERHUB_TOKEN` is intentionally **not** `VAST_`-prefixed — that prefix is
  reserved for tokens `vast-account-vars-set` auto-syncs into every instance, and
  this one must stay Mac-side/rent-time only. Don't "fix" it to match the pattern.
- Update `README.md` for user-facing changes; CI (`nix flake check`, which now
  carries the formatting gate as `checks.treefmt`) must pass.
