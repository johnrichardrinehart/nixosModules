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

## SSH tmux sessions

The laptop profile starts each interactive SSH shell in a new tmux session.
Each session receives the tmux user option `@ssh-session=1`.
The option remains set when the user renames the session.

Start a session with an initial human-readable name:

```console
$ ssh -t john@$HOST ssh-session new project-name
```

Start a direct login shell without tmux:

```console
$ ssh -t john@$HOST ssh-session shell
```

This command does not create or attach a tmux session.

Rename it at any time without removing the option:

```console
$ tmux rename-session project-renamed
```

List SSH-created sessions and their stable handles:

```console
$ ssh john@$HOST ssh-session list
```

Attach to a session by its handle or exact current name:

```console
$ ssh -t john@$HOST ssh-session attach s14
$ ssh -t john@$HOST ssh-session attach project-name
```

`ssh-session attach` rejects unmarked sessions and never creates a replacement.
A plain interactive SSH login always creates a separate session.
The helper does not remove detached sessions automatically.

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

## Brightness keys

`brightness-notify` (bound to the Niri brightness keys) moves a logical level
between 0 and 100% in 4% steps. At 60% and above, the hardware brightness
equals the level. Below 60%, the hardware brightness falls linearly to 24% at
level 4 and about 21% at level 0. The laptop backlight and external monitors'
DDC/CI brightness (VCP `0x10`) follow the hardware brightness. A software factor
on every output equals the hardware brightness divided by 60%, so software does
more of the dimming the lower you go.

The factor is published at
`$XDG_RUNTIME_DIR/brightness-notify/software-brightness`. When
`daylightDisplay` is enabled, daylight-display multiplies it into its own
brightness and reapplies it immediately on `SIGUSR1`. Otherwise
`brightness-notify` sets it directly through `wl-gammarelay-rs`, if that is
running.

The `brightness-sync` user unit, enabled by
`dev.johnrinehart.desktop.displayBrightness.enable` (on by default in the laptop
profile, together with `hardware.i2c`), owns DDC/CI: `brightness-notify` signals it
(`SIGUSR1`) after each level change, and it rescans monitors with `ddcutil`
after DRM hotplug events (3 s and 15 s after the last event, to give monitors
behind DisplayPort MST time to answer). At login and after hotplug it also
reapplies the software factor. Monitors need DDC/CI enabled in their OSD, and
Dell's Auto Brightness should be off so it does not fight the written value.

## Git commit transfer

The `git-patch-wormhole` package transfers one or more Git heads over Magic
Wormhole. Each ZIP contains a Git bundle with the exact commit objects and the
metadata required to restore them. It is included when
`dev.johnrinehart.packages.shell.enable` is enabled.

Describe each head as `<base>:<branch>:<revision-range>`. The receiver creates
each named branch at the recorded base and fast-forwards it to the original
tip, preserving every commit hash:

```console
$ git patch-wormhole send main:feature:main..feature release:hotfix:release..hotfix
$ git patch-wormhole receive 7-example-code
```

The exact base commit must already exist in the receiving repository. Leave the
branch field empty to restore a detached head:

```console
$ git patch-wormhole send main::main..experiment
```

For a single head, pass a Git revision selection directly:

```console
$ git patch-wormhole send main..feature
```

It restores onto the current branch when that branch is at the original base.
`--branch` creates a named branch, while `--base` checks out an existing branch,
tag, or commit that must resolve to the original base:

```console
$ git patch-wormhole receive 7-example-code --branch feature --base main
```

A commit hash includes its parent hash, so moving commits to a different base
cannot preserve its identity. The tool is for exact repository synchronization
and intentionally rejects that operation.

The receiving worktree must be clean. Multi-head archives always restore their
recorded bases and branch names; they reject `--branch` and `--base`.

