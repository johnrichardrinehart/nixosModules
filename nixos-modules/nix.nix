{
  inputs,
  config,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.nix;
in
{
  options.dev.johnrinehart.nix = {
    enable = lib.mkEnableOption "reasonable Nix settings";

    trusted-users = lib.mkOption {
      default = builtins.attrNames (lib.filterAttrs (_: v: v.isNormalUser) config.users.users) ++ [
        "@wheel"
      ];
    };

    allowedUnfreePackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Package names permitted by nixpkgs' unfree predicate.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.allowedUnfreePackages != [ ]) {
      nixpkgs.config.allowUnfreePredicate =
        pkg: builtins.elem (lib.getName pkg) cfg.allowedUnfreePackages;
    })

    (lib.mkIf cfg.enable {
      nix = {
        registry = {
          nixpkgs.flake = inputs.nixpkgs;
        };

        nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

        settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

        settings.download-buffer-size = 256 * 1024 * 1024;

        settings.trusted-users = cfg.trusted-users;
      };
    })
  ];
}
