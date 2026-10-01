{
  bash,
  context-mode,
  fetchpatch2,
  lib,
  nix,
  nodejs,
  python3,
  writeShellApplication,
  writeText,
}:
let
  # can1357/oh-my-pi#13820: detect Monstar and send notifications through
  # OSC 9. The CHANGELOG hunk conflicts with released omp, so it is excluded.
  monstarPatch = fetchpatch2 {
    name = "omp-monstar-terminal-detection.patch";
    url = "https://github.com/can1357/oh-my-pi/commit/1458f84ec4bd0eb2bccfedeafa7a0bde06171161.patch";
    excludes = [ "packages/tui/CHANGELOG.md" ];
    hash = "sha256-t7vE0hJCt7Vty8jgVuSccHsESbwkPJs5PX1xMY8QUW0=";
  };
  # The wrapper evaluates the current llm-agents.nix omp at start-up. The patch
  # is applied when it applies cleanly to that omp; otherwise (a release that
  # already contains the change, or one that conflicts) omp builds unpatched
  # with a warning instead of failing in the patch phase.
  ompExpr = writeText "omp.nix" ''
    let
      omp = (builtins.getFlake "github:numtide/llm-agents.nix").packages.''${builtins.currentSystem}.omp;
      monstarPatch = builtins.storePath "${monstarPatch}";
    in
    omp.overrideAttrs (old: {
      prePatch = (old.prePatch or "") + '''
        if patch -p1 --forward --dry-run --silent < ''${monstarPatch}; then
          patch -p1 --forward < ''${monstarPatch}
        else
          echo "warning: Monstar terminal detection patch does not apply to omp $version; building unpatched" >&2
        fi
      ''';
    })
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
        exec nix --tarball-ttl 86400 run --impure --file ${ompExpr} "" -- ${
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
