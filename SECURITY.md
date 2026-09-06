# Security Policy

## The model (important)

`nix-vast-provision` never writes secrets to the Nix store, git, or a Vast.ai
**template** (templates are visible in the account's template list and, if
marked public, to anyone). Instead:

- **Source of truth on the Mac:** the login Keychain (`VAST_API_KEY`,
  `GITLAB_TOKEN`, `HF_TOKEN`, `CIVITAI_API_TOKEN`,
  `GITHUB_PERSONAL_ACCESS_TOKEN`, ...), read via
  `/usr/bin/security find-generic-password`. There is no `VAST_`-prefixed copy of
  anything, and therefore no prefix left to signal "safe to sync" — the Vast
  variable names are fixed by what the container reads, and the Keychain entry
  behind each is the operator's general token (see the README's alias table).
  **What you pass to `vast-account-vars-set` is what leaves the machine**, so keep
  those tokens read-only. `vast-template-apply`
  and friends never print a token value — only lengths, as round-trip proof.
- **Delivery to instances:** `vast-account-vars-set` pushes those Keychain
  values to Vast.ai **account-level** environment variables (`POST/PUT
  /api/v0/secrets/`), which Vast injects into every instance you launch,
  regardless of template. The template itself carries no secret — only
  non-secret config (`PROVISION_REPO`, `PROVISION_REF`, ...).
- **Untrusted-host reality:** Vast GPU hosts are third parties. Any token
  injected into a running instance is visible to whoever controls that host.
  Account variables keep secrets out of the template *blob*, not out of the
  *running container*. Use narrowly-scoped, read-only tokens (e.g. a GitLab
  `read_repository` deploy token) as the mitigation — never a write-scoped or
  full personal access token.
- **Public bootstrap, secret-free by construction:** `packages/vast-bootstrap.sh`
  is fetched *anonymously* by the Vast base image at boot. It contains no
  secret and clones your (possibly private) provisioner repo using a token
  read from the container's environment — never embedded in the script or the
  template.

## Reporting a vulnerability

Please open a **private** security advisory via GitHub
("Security" → "Report a vulnerability"), or contact the maintainer directly.
Do not file public issues for undisclosed vulnerabilities.
