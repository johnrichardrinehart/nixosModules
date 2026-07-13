{
  inputs,
  lib,
  pkgs,
}:
let
  evaluated = lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      (import ../../nixos-modules { inherit inputs lib; })
      {
        nixpkgs.pkgs = pkgs;
        system.stateVersion = "24.05";

        # Deliberately enable no desktop variant: application availability is
        # independent of Xorg, Wayland, window managers, and compositors.
        dev.johnrinehart.desktop.obsidian.enable = true;
        dev.johnrinehart.voice-dictation.enable = true;
      }
    ];
  };
  cfg = evaluated.config;
  packageNames = map lib.getName cfg.environment.systemPackages;
  allowUnfree = cfg.nixpkgs.config.allowUnfreePredicate;
in
assert builtins.elem "obsidian" packageNames;
assert allowUnfree pkgs.obsidian;
assert allowUnfree pkgs.dev.johnrinehart.moonshine-models-source;
assert !allowUnfree pkgs.slack;
pkgs.runCommand "obsidian-module-evaluation" { } ''
  touch $out
''
