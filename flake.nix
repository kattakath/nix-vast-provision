{
  description = "Nix flake — Vast.ai GPU-template provisioning toolkit for macOS: reconcile templates (legacy bash-engine, aggregator, or native-manifest mode) via PROVISIONING_SCRIPT, validate provisioner repos, sync account-level secrets, scaffold new provisioner repos, and rent instances with authenticated Docker Hub pulls.";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://kattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "kattakath.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw="
    ];
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      ...
    }:
    let
      # Default coordinates for the raw-URL PROVISIONING_SCRIPT this toolkit generates
      # (i.e. which repo's packages/vast-bootstrap.sh + provision-lib.sh get fetched by
      # a Vast instance at first boot). Default to THIS flake's own GitHub repo, so the
      # toolkit works out of the box; override both if you forked it — see
      # packages/vast-provision.nix's header comment for the callPackage override.
      orgName = "kattakath";
      repoName = "nix-vast-provision";
      # Cross-service handle used ONLY by vast-rent, as the Docker Hub username paired
      # with the Keychain's DOCKERHUB_TOKEN for the per-instance image_login. Override
      # via callPackage if you fork this and use a different Docker Hub account.
      userName = "ismailkattakath";

      mkKit =
        pkgs:
        pkgs.callPackage ./packages/vast-provision.nix {
          inherit orgName repoName userName;
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
        "vast-rent"
      ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];

      # macOS-only toolkit: every app shells out to /usr/bin/security (the login
      # Keychain). NEVER add x86_64-darwin — nixpkgs-unstable dropped it, so
      # `nix flake show --all-systems` throws.
      systems = [ "aarch64-darwin" ];

      perSystem =
        { pkgs, system, ... }:
        let
          kit = mkKit pkgs;
        in
        {
          # The CLIs, runnable via `nix run .#<name>` or wired into another flake's
          # `packages`/`apps` (see the README's "Used in production" link).
          packages = {
            vast-template-apply = kit.template-apply;
            vast-repo-check = kit.repo-check;
            vast-account-vars-set = kit.account-vars-set;
            vast-ssh-key-set = kit.ssh-key-set;
            vast-init-repo = kit.init-repo;
            vast-rent = kit.rent;
            default = kit.template-apply;
          };

          apps =
            pkgs.lib.genAttrs appNames (name: {
              type = "app";
              program = "${self.packages.${system}.${name}}/bin/${name}";
            })
            // {
              default = {
                type = "app";
                program = "${self.packages.${system}.vast-template-apply}/bin/vast-template-apply";
              };
            };

          # `nix flake check` BUILDS every writeShellApplication above (each build runs
          # shellcheck) plus scripts-lint (shellchecks the committed instance-side
          # scripts that can't be writeShellApplications, since they're served as raw
          # files / fetched at instance-boot time) — proving the whole toolkit
          # evaluates + lints.
          checks = (pkgs.lib.getAttrs appNames self.packages.${system}) // {
            inherit (kit) scripts-lint;
          };

          # treefmt owns `nix fmt` and contributes its own `checks.treefmt`, so CI
          # formatting is gated by THIS flake's lock rather than the runner's
          # registry. Bare nixfmt as the formatter is a trap: `nix fmt` hands it
          # every file in the tree, including README.md and LICENSE, which it
          # cannot parse.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.deadnix.enable = true;
            programs.statix.enable = true;
          };
        };
    };
}
