{
  lib,
  python3,
  writeScriptBin,
}:
writeScriptBin "git-fsmonitor-host-watchman" (
  "#!${lib.getExe python3}\n" + builtins.readFile ./git-fsmonitor-host-watchman.py
)
