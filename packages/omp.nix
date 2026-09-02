{
  bash,
  context-mode,
  lib,
  nix,
  nodejs,
  python3,
  writeShellApplication,
}:
let
  pluginSet = {
    inherit context-mode;
  };
  pluginPath = plugin: "${plugin}/lib/node_modules/${lib.getName plugin}";
  makeOmp =
    plugins:
    (writeShellApplication {
      name = "omp";
      runtimeInputs = [
        bash
        nix
        nodejs
        python3
      ]
      ++ plugins;
      text = ''
        exec nix --tarball-ttl 3600 run github:numtide/llm-agents.nix#omp -- ${
          lib.escapeShellArgs (
            lib.concatMap (plugin: [
              "--extension"
              (pluginPath plugin)
            ]) plugins
          )
        } "$@"
      '';

      meta = {
        description = "Shell wrapper that runs OMP through llm-agents.nix";
        license = lib.licenses.mit;
        mainProgram = "omp";
        maintainers = [ ];
        platforms = lib.platforms.linux ++ lib.platforms.darwin;
      };
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          inherit plugins;
          withPlugins = select: makeOmp (lib.unique (plugins ++ select pluginSet));
        };
      });
in
makeOmp [ ]
