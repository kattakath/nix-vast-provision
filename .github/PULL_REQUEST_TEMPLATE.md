## What & why

## Checklist
- [ ] `nix flake check -L` passes (shellcheck for every CLI + scripts-lint + treefmt)
- [ ] `nix fmt` run (treefmt: nixfmt + deadnix + statix)
- [ ] No secret values added; templates stay secret-free (account-level vars only)
