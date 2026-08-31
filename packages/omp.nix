{
  bash,
  lib,
  nix,
  nodejs,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "omp";
  runtimeInputs = [
    bash
    nix
    nodejs
    python3
  ];
  text = ''
    exec nix --tarball-ttl 3600 run github:numtide/llm-agents.nix#omp -- "$@"
  '';

  meta = with lib; {
    description = "Shell wrapper that runs OMP through llm-agents.nix";
    license = licenses.mit;
    mainProgram = "omp";
    maintainers = [ ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
