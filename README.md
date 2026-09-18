# nixosModules

Reusable JohnOS NixOS modules, overlays, packages, Home Manager modules, and
supporting assets.

This repository is intended to be consumed as a flake input by host/system
configuration repositories. It exposes:

- `lib`
- `nixosModules.default`
- `overlays.default`
- per-system `packages`
- per-system `legacyPackages`

The companion host configuration repository is
[`nixosConfigurations`](https://github.com/johnrichardrinehart/nixosConfigurations).

## Display breakpoint helper

Consumers can build custom daylight-display schedules with the exported helper:

```nix
let
  breakpoint = inputs.nixosModules.lib.daylightDisplay.breakpoint;
in
{
  dev.johnrinehart.desktop.daylightDisplay.breakpoints = [
    (breakpoint "sunrise" 45 95 6250)
    (breakpoint "sunset" (-15) 35 3750)
  ];
}
```

The arguments are the solar event, offset in minutes, brightness percentage,
and color temperature in kelvin.

## Git patch transfer

The `git-patch-wormhole` package transfers a Git revision selection as
format-patch files over Magic Wormhole. It is included when
`dev.johnrinehart.packages.shell.enable` is enabled.

Send the commits selected by any `git format-patch` revision arguments:

```console
$ git patch-wormhole send main..feature
```

On the receiving machine, apply the patches to the current branch:

```console
$ git patch-wormhole receive 7-example-code
```

To create a branch at a specific base before applying:

```console
$ git patch-wormhole receive 7-example-code --branch feature --base main
```

The receiving worktree must be clean. `--base` without `--branch` behaves like
`git checkout <base>`: existing branches stay attached, while tags and commit
references produce detached HEADs.

