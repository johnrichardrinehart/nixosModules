{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.hardware.i915;
  supervisorEnabled = config.services.wayland-session-supervisor.enable;
  patchEnabled = cfg.checkpointRestore.enable;
  applicable =
    cfg.enable
    && cfg.deviceId != null
    && builtins.elem (lib.toLower cfg.deviceId) (map lib.toLower cfg.supportedDeviceIds);
in
{
  options.dev.johnrinehart.hardware.i915 = {
    enable = lib.mkEnableOption "an Intel i915 hardware profile";

    deviceId = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[0-9A-Fa-f]{4}");
      default = null;
      example = "9a49";
      description = "Four-digit PCI device ID used to select reviewed i915 patches.";
    };

    supportedDeviceIds = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9A-Fa-f]{4}");
      default = [ "9a49" ];
      description = "i915 PCI device IDs covered by the experimental checkpoint patch.";
    };

    matchesCheckpointHardware = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Whether the configured i915 device matches the reviewed checkpoint target.";
    };

    checkpointRestore = {
      enable = lib.mkEnableOption "the experimental i915 CRIU kernel ABI";

      kernelVersion = lib.mkOption {
        type = lib.types.str;
        default = "7.1.4";
        description = "Exact kernel version against which the experimental patch was generated.";
      };
    };
  };

  config = {
    dev.johnrinehart.hardware.i915.matchesCheckpointHardware = applicable;

    assertions = [
      {
        assertion = !patchEnabled || cfg.enable;
        message = "i915 checkpointRestore requires dev.johnrinehart.hardware.i915.enable";
      }
      {
        assertion = !patchEnabled || applicable;
        message = "i915 checkpointRestore is not reviewed for the configured PCI device ID";
      }
      {
        assertion = !patchEnabled || pkgs.stdenv.hostPlatform.isx86_64;
        message = "i915 checkpointRestore currently supports only x86_64-linux";
      }
      {
        assertion =
          !patchEnabled || config.boot.kernelPackages.kernel.version == cfg.checkpointRestore.kernelVersion;
        message = "i915 checkpointRestore patch requires kernel ${cfg.checkpointRestore.kernelVersion}";
      }
      {
        assertion = !(supervisorEnabled && cfg.enable) || patchEnabled;
        message = "wayland-session-supervisor on configured i915 hardware requires i915 checkpointRestore.enable";
      }
    ];

    boot.kernelPatches = lib.mkIf patchEnabled [
      {
        name = "i915-criu";
        patch = ./criu.patch;
      }
    ];
  };
}
