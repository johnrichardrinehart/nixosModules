{
  bash,
  context-mode,
  lib,
  nix,
  nodejs,
  python3,
  writeShellApplication,
  writeText,
}:
let
  # Backport of https://github.com/can1357/oh-my-pi/pull/13820. The PR commit
  # does not apply to omp 18.3.2. When llm-agents ships omp 18.4.4 or later,
  # replace the vendored patch with a fetchpatch2 of commit
  # 1458f84ec4bd0eb2bccfedeafa7a0bde06171161.
  patchedVersion = "18.3.2";
  # The wrapper evaluates the current llm-agents.nix omp at start-up. It
  # applies the patch only to the version the patch targets, so a newer omp
  # starts unpatched instead of failing in the patch phase.
  ompExpr = writeText "omp.nix" ''
    let
      omp = (builtins.getFlake "github:numtide/llm-agents.nix").packages.''${builtins.currentSystem}.omp;
    in
    if omp.version == "${patchedVersion}" then
      omp.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ (builtins.storePath "${./monstar-terminal-detection.patch}") ];
      })
    else
      omp
  '';
  pluginSet = {
    inherit context-mode;
  };
  pluginPath = plugin: "${plugin}/lib/node_modules/${lib.getName plugin}";
  pluginRuntimeInputs =
    plugins: lib.unique (lib.concatMap (plugin: plugin.ompRuntimeInputs or [ ]) plugins);
  makeOmp =
    plugins:
    let
      runtimeInputs = [
        bash
        nix
        nodejs
        python3
      ]
      ++ pluginRuntimeInputs plugins
      ++ plugins;
    in
    (writeShellApplication {
      name = "omp";
      inherit runtimeInputs;
      text = ''
        exec nix --tarball-ttl 3600 run --impure --file ${ompExpr} "" -- ${
          lib.escapeShellArgs (
            lib.concatMap (plugin: [
              "--extension"
              (pluginPath plugin)
            ]) plugins
          )
        } "$@"
      '';

      meta = {
        description = "Shell wrapper that runs patched OMP through llm-agents.nix";
        license = lib.licenses.mit;
        mainProgram = "omp";
        maintainers = [ ];
        platforms = lib.platforms.linux ++ lib.platforms.darwin;
      };
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          inherit plugins runtimeInputs;
          pluginRuntimeInputs = pluginRuntimeInputs plugins;
          withPlugins = select: makeOmp (lib.unique (plugins ++ select pluginSet));
        };
      });
in
makeOmp [ ]
