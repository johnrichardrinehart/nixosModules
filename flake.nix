{
  description = "Reusable JohnOS NixOS modules, overlays, and packages";

  inputs = {
    nixpkgs.url = "github:johnrichardrinehart/nixpkgs?ref=rock-5c-nixos-26.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    display-layout = {
      url = "github:johnrichardrinehart/display-layout";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wayland-session-supervisor = {
      url = "github:johnrichardrinehart/wayland-session-supervisor";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      flake = true;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      allowMoonshineModels = pkg: (inputs.nixpkgs.lib.getName pkg) == "moonshine-models-source";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.flake-parts.flakeModules.partitions ];

      systems = [ "x86_64-linux" ];

      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      partitions.dev = {
        extraInputsFlake = ./dev;
        module =
          { inputs, ... }:
          {
            perSystem =
              { system, ... }:
              let
                overlays = import ./overlays inputs;
                pkgs = import inputs.nixpkgs {
                  inherit system;
                  overlays = [ overlays.default ];
                  config.allowUnfreePredicate = allowMoonshineModels;
                };
                treefmtEval = inputs."treefmt-nix".lib.evalModule pkgs ./treefmt.nix;
                preCommitCheck = inputs."git-hooks".lib.${system}.run {
                  src = ./.;
                  hooks = {
                    treefmt-nix = {
                      enable = true;
                      name = "treefmt";
                      entry = "${treefmtEval.config.build.wrapper}/bin/treefmt --fail-on-change";
                      language = "system";
                      pass_filenames = false;
                    };
                  };
                };
              in
              {
                devShells = import ./dev-shells.nix {
                  inherit pkgs;
                  inherit preCommitCheck;
                  treefmtBin = treefmtEval.config.build.wrapper;
                };

                checks = {
                  pre-commit = preCommitCheck;
                  formatting = treefmtEval.config.build.check inputs.self;
                  agent-tools-module = import ./nix/checks/agent-tools-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  i915-module = import ./nix/checks/i915-module.nix {
                    inherit pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  greetd-niri-pam-module = import ./nix/checks/greetd-niri-pam-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  obsidian-module = import ./nix/checks/obsidian-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                };

                formatter = treefmtEval.config.build.wrapper;
              };
          };
      };

      flake = {
        lib = inputs.nixpkgs.lib;

        nixosModules.default = import ./nixos-modules {
          inherit inputs;
          inherit (inputs.nixpkgs) lib;
        };

        overlays = import ./overlays inputs;
      };

      perSystem =
        { system, ... }:
        let
          overlays = import ./overlays inputs;
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ overlays.default ];
            config.allowUnfreePredicate = allowMoonshineModels;
          };
        in
        {
          packages = import ./packages { inherit pkgs; };
          legacyPackages = pkgs;
        };
    };
}
