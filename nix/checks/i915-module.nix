{ lib, pkgs }:
let
  optionStubs = {
    options = {
      services.wayland-session-supervisor.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      boot.kernelPackages.kernel.version = lib.mkOption {
        type = lib.types.str;
        default = "7.1.3";
      };
      boot.kernelPatches = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
    };
  };
  evaluate =
    module:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        optionStubs
        ../../nixos-modules/hardware/i915
        module
      ];
    };
  disabled = (evaluate { }).config;
  enabled =
    (evaluate {
      dev.johnrinehart.hardware.i915 = {
        enable = true;
        deviceId = "9a49";
        checkpointRestore.enable = true;
      };
      services.wayland-session-supervisor.enable = true;
    }).config;
  nonI915 =
    (evaluate {
      dev.johnrinehart.hardware.i915 = {
        enable = true;
        deviceId = "ffff";
      };
    }).config;
  incompatible =
    (evaluate {
      dev.johnrinehart.hardware.i915 = {
        enable = true;
        deviceId = "9a49";
      };
      services.wayland-session-supervisor.enable = true;
    }).config;
  patchNames = config: map (patch: patch.name) config.boot.kernelPatches;
  failedAssertions = config: builtins.filter (assertion: !assertion.assertion) config.assertions;
  patchHash = builtins.hashFile "sha256" ../../nixos-modules/hardware/i915/criu.patch;
in
# Pin the complete aggregate patch instead of recursively scanning its large
# text during evaluation. The hash covers both i915 ABI 14 and evdev ABI 1.
assert patchHash == "3165b41384f99f482b2678831b531f77fee009f71f00f888374083100e86b75b";
assert patchNames disabled == [ ];
assert !disabled.dev.johnrinehart.hardware.i915.matchesCheckpointHardware;
assert patchNames enabled == [ "i915-criu" ];
assert enabled.dev.johnrinehart.hardware.i915.matchesCheckpointHardware;
assert failedAssertions enabled == [ ];
assert patchNames nonI915 == [ ];
assert !nonI915.dev.johnrinehart.hardware.i915.matchesCheckpointHardware;
assert builtins.length (failedAssertions incompatible) == 1;
pkgs.runCommand "i915-module-evaluation" { } ''
  touch $out
''
