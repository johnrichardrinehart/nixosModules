{
  lib,
  python3,
  stdenv,
  watchman,
  writeScriptBin,
}:
let
  # Only the host runs a watchman of its own; the guest reaches the host's
  # through the launcher's bridge and has no use for one in its closure.
  watchmanBin = if stdenv.hostPlatform.isDarwin then lib.getExe' watchman "watchman" else "watchman";
in
writeScriptBin "git-fsmonitor-host-watchman" (
  "#!${lib.getExe python3}\n"
  + builtins.replaceStrings [ "@watchman@" ] [ watchmanBin ] (
    builtins.readFile ./git-fsmonitor-host-watchman.py
  )
)
