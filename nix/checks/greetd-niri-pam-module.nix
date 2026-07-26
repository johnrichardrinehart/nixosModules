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
        nixpkgs.hostPlatform = "x86_64-linux";
        nixpkgs.overlays = [ (import ../../overlays inputs).default ];
        system.stateVersion = "24.05";

        dev.johnrinehart.desktop = {
          enable = true;
          variant = "greetd+niri";
          greetd_niri.fingerprint.enable = true;
        };
      }
    ];
  };
  pamServices = evaluated.config.security.pam.services;
  pamText = name: pamServices.${name}.text;
  hasKeyring = name: lib.hasInfix "pam_gnome_keyring.so" (pamText name);
  hasKeyringAutoStart = name: lib.hasInfix "pam_gnome_keyring.so auto_start" (pamText name);
  hasFingerprint = name: lib.hasInfix "pam_fprintd.so timeout=15" (pamText name);
  userSessionServices = [
    "greetd"
    "hyprlock"
    "login"
    "swaylock"
  ];
  authorizationServices = [
    "polkit-1"
    "sudo"
  ];
in
assert builtins.all hasKeyring userSessionServices;
assert builtins.all hasKeyringAutoStart userSessionServices;
assert builtins.all (name: pamServices.${name}.enableGnomeKeyring) userSessionServices;
assert builtins.all (name: !hasKeyring name) authorizationServices;
assert builtins.all (name: !pamServices.${name}.enableGnomeKeyring) authorizationServices;
assert builtins.all hasFingerprint (userSessionServices ++ authorizationServices);
pkgs.runCommand "greetd-niri-pam-module-evaluation" { } ''
  touch $out
''
