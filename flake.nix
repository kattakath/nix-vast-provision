{
  description = "Nix flake — Vast.ai GPU-template provisioning toolkit for macOS: reconcile vastai/base-image templates via PROVISIONING_SCRIPT, validate provisioner repos, sync account-level secrets, and scaffold new provisioner repos from a generic template.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  nixConfig = {
    extra-substituters = [ "https://ismailkattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      inherit (nixpkgs) lib;
      # macOS-only toolkit: every app shells out to /usr/bin/security (the login
      # Keychain). NEVER add x86_64-darwin — nixpkgs-unstable dropped it, so
      # `nix flake show --all-systems` throws.
      darwinSystems = [ "aarch64-darwin" ];
      forAll = systems: f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # Default coordinates for the raw-URL PROVISIONING_SCRIPT this toolkit generates
      # (i.e. which repo's packages/vast-bootstrap.sh + provision-lib.sh get fetched by
      # a Vast instance at first boot). Default to THIS flake's own GitHub repo, so the
      # toolkit works out of the box; override both if you forked it — see
      # packages/vast-provision.nix's header comment for the callPackage override.
      orgName = "ismailkattakath";
      repoName = "nix-vast-provision";

      mkKit =
        pkgs:
        pkgs.callPackage ./packages/vast-provision.nix {
          inherit orgName repoName;
          # self.rev is only set when evaluated from a clean, committed git tree (e.g.
          # CI, or `nix run github:...`); a dirty/local checkout falls back to "main" so
          # local dev still evaluates (the generated PROVISIONING_SCRIPT URL just won't
          # be pinned to an exact commit until you push).
          rev = self.rev or "main";
        };

      appNames = [
        "vast-template-apply"
        "vast-repo-check"
        "vast-account-vars-set"
        "vast-ssh-key-set"
        "vast-init-repo"
      ];
    in
    {
      # The CLIs, runnable via `nix run .#<name>` or wired into another flake's
      # `packages`/`apps` (see the README's "Used in production" link).
      packages = forAll darwinSystems (
        _: pkgs:
        let
          kit = mkKit pkgs;
        in
        {
          vast-template-apply = kit.template-apply;
          vast-repo-check = kit.repo-check;
          vast-account-vars-set = kit.account-vars-set;
          vast-ssh-key-set = kit.ssh-key-set;
          vast-init-repo = kit.init-repo;
          default = kit.template-apply;
        }
      );

      apps = forAll darwinSystems (
        system: _:
        lib.genAttrs appNames (name: {
          type = "app";
          program = "${self.packages.${system}.${name}}/bin/${name}";
        })
        // {
          default = {
            type = "app";
            program = "${self.packages.${system}.vast-template-apply}/bin/vast-template-apply";
          };
        }
      );

      # `nix flake check` BUILDS every writeShellApplication above (each build runs
      # shellcheck) plus scripts-lint (shellchecks the committed instance-side scripts
      # that can't be writeShellApplications, since they're served as raw files /
      # fetched at instance-boot time) — proving the whole toolkit evaluates + lints.
      checks = forAll darwinSystems (
        system: pkgs:
        let
          kit = mkKit pkgs;
        in
        (lib.getAttrs appNames self.packages.${system})
        // {
          inherit (kit) scripts-lint;
        }
      );

      formatter = forAll darwinSystems (_: pkgs: pkgs.nixfmt-rfc-style);
    };
}
