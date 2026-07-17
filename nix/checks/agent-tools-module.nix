{
  inputs,
  lib,
  pkgs,
}:
let
  evaluate =
    agentTools:
    lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        (import ../../nixos-modules { inherit inputs lib; })
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          nixpkgs.overlays = [ (import ../../overlays inputs).default ];
          system.stateVersion = "24.05";
          dev.johnrinehart.agentTools = agentTools;
        }
      ];
    };
  profile = (evaluate { enable = true; }).config;
  piOnly = (evaluate { pi.enable = true; }).config;
  codexOnly = (evaluate { codexCli.enable = true; }).config;
  claudeOnly = (evaluate { claudeCodeCli.enable = true; }).config;
  omxProfile = (evaluate { "oh-my-codex".enable = true; }).config;
  invalidOmxProfile =
    (evaluate {
      "oh-my-codex".enable = true;
      codexCli.enable = false;
    }).config;
  packageNames = config: map lib.getName config.environment.systemPackages;
  failedAssertions = config: builtins.filter (entry: !entry.assertion) config.assertions;
in
assert builtins.all (name: builtins.elem name (packageNames profile)) [
  "pi"
  "codex-cli-nix"
  "claude-code-nix"
];
assert !(profile.users.users ? pi);
assert !(profile.users.users ? codex);
assert !(profile.users.users ? claude);
assert builtins.elem "pi" (packageNames piOnly);
assert !(builtins.elem "codex-cli-nix" (packageNames piOnly));
assert !(builtins.elem "claude-code-nix" (packageNames piOnly));
assert builtins.elem "codex-cli-nix" (packageNames codexOnly);
assert !(builtins.elem "pi" (packageNames codexOnly));
assert !(builtins.elem "claude-code-nix" (packageNames codexOnly));
assert codexOnly.environment.etc ? "codex/config.toml";
assert builtins.elem "claude-code-nix" (packageNames claudeOnly);
assert !(builtins.elem "pi" (packageNames claudeOnly));
assert !(builtins.elem "codex-cli-nix" (packageNames claudeOnly));
assert builtins.elem "codex-cli-nix" (packageNames omxProfile);
assert builtins.elem "oh-my-codex" (packageNames omxProfile);
assert omxProfile.environment.etc ? "codex/config.toml";
assert omxProfile.environment.etc ? "codex/hooks.json";
assert builtins.any (
  entry:
  entry.message
  == "dev.johnrinehart.agentTools.oh-my-codex.enable requires dev.johnrinehart.agentTools.codexCli.enable"
) (failedAssertions invalidOmxProfile);
assert !(invalidOmxProfile.environment.etc ? "codex/config.toml");
assert !(invalidOmxProfile.environment.etc ? "codex/hooks.json");
pkgs.runCommand "agent-tools-module-evaluation" { } ''
  touch $out
''
