# nixosModules

## Wayland session supervision

Clients using the supported greetd+Niri desktop can opt into exact session
checkpoint/restore supervision through the project-owned module:

```nix
services.wayland-session-supervisor.enable = true;
```

The module detects greetd and Niri, infers the sole normal login user, replaces
the greeter's compositor command, and owns automatic capture and authenticated
restore. Advanced configurations may explicitly set the user or structured
compositor argv. The pinned project input supplies the supervisor package and
its shared CRIU 4.2 overlay.

Experimental physical Intel GPU restoration patches are hardware-gated:

```nix
dev.johnrinehart.hardware.i915 = {
  enable = true;
  deviceId = "9a49";
  checkpointRestore.enable = true;
};
```

`matchesCheckpointHardware` is a read-only predicate derived from the profile
and reviewed PCI IDs. The patch is applied only with explicit opt-in, an exact
supported kernel version, x86_64, and a matching device. Enabling the session
supervisor on a declared i915 host without the checkpoint patch is rejected;
non-i915 and disabled configurations receive no kernel patch.

Because exact physical Niri supervision keeps `seatd` in the checkpoint domain,
the gated patch also carries the version-1 read-only evdev admission query used
by CRIU. It admits only default-empty clients and reports queued events, grabs,
filters, force-feedback capability, clock, and buffer bounds so unsupported
input state fails before an image is accepted. It does not make arbitrary input
devices checkpointable.

Reusable JohnOS NixOS modules, overlays, packages, Home Manager modules, and
supporting assets.

This repository is intended to be consumed as a flake input by host/system
configuration repositories. It exposes:

- `nixosModules.default`
- `overlays.default`
- per-system `packages`
- per-system `legacyPackages`

The companion host configuration repository is
[`nixosConfigurations`](https://github.com/johnrichardrinehart/nixosConfigurations).
