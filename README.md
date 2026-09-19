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

The `git-patch-wormhole` package transfers one or more Git heads as
format-patch files over Magic Wormhole. It is included when
`dev.johnrinehart.packages.shell.enable` is enabled.

Describe each head as `<base>:<branch>:<revision-range>`. The sender records the
exact base commit, and the receiver creates each named branch at that base
before applying its patches:

```console
$ git patch-wormhole send main:feature:main..feature release:hotfix:release..hotfix
$ git patch-wormhole receive 7-example-code
```

The base commit must already exist in the receiving repository. Leave the
branch field empty to apply a head in detached-HEAD state; the receiver prints
the resulting commit so it can be retained later:

```console
$ git patch-wormhole send main::main..experiment
```

The original single-head form remains available. It passes all arguments to
`git format-patch`:

```console
$ git patch-wormhole send main..feature
```

Legacy archives apply to the current branch by default. To create a branch at a
specific base before applying one:

```console
$ git patch-wormhole receive 7-example-code --branch feature --base main
```

The receiving worktree must be clean. For legacy archives, `--base` without
`--branch` behaves like `git checkout <base>`: existing branches stay attached,
while tags and commit references produce detached HEADs. Multi-head archives
store their own bases and branch names, so they reject `--base` and `--branch`.

