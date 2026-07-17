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
  packageNames = config: map lib.getName config.environment.systemPackages;
in
assert builtins.all (name: builtins.elem name (packageNames profile)) [
  "pi"
  "codex-cli-nix"
  "claude-code-nix"
];
assert !(profile.users.users ? pi);
assert !(profile.users.users ? codex);
assert !(profile.users.users ? claude);
pkgs.runCommand "agent-tools-module-evaluation" { } ''
  touch $out
''
