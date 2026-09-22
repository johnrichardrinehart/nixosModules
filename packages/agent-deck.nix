{
  lib,
  buildGo126Module,
  fetchFromGitHub,
  git,
  openssh,
  tmux,
}:
buildGo126Module rec {
  pname = "agent-deck";
  version = "1.16.16";

  src = fetchFromGitHub {
    owner = "asheshgoplani";
    repo = "agent-deck";
    rev = "v${version}";
    hash = "sha256-+0T8ZJP+7W+QOT1dgVVmg46CCzM1O1UIg1+4CL8pMPE=";
  };

  vendorHash = "sha256-ZIBWsEa6IpoW66/kd40UNihBrbo5yjCsRIQatCbt4q8=";

  subPackages = [ "cmd/agent-deck" ];

  nativeCheckInputs = [
    git
    openssh
    tmux
  ];
  checkFlags = [
    # Keep the rest of the package tests enabled while skipping sandbox-sensitive
    # remote-execution and interactive TUI timing checks.
    "-skip=TestRemoteCommandParity|TestRemoteSuccessfulMutationParity|TestCloseSessionWindow_KillsExtraWindow|TestLogCgroupIsolationDecision_WiredIntoBootstrap/tui_startup_emits_line|TestPerf_ColdStart_(Help|Version)|TestStatusStale_CLI_CandidateViewAndMutatesNothing"
  ];

  preCheck = ''
    export TMPDIR=/tmp/agent-deck-tests
    export HOME="$TMPDIR/home"
    # Nix builders have variable startup latency. Use the multiplier that
    # upstream applies in CI while retaining the performance regression tests.
    export PERF_BUDGET_MULTIPLIER=2.0
    mkdir -p "$TMPDIR"
    mkdir -p "$HOME"
  '';

  meta = with lib; {
    description = "Your AI agent command center - manage multiple AI coding agents from one terminal";
    homepage = "https://github.com/asheshgoplani/agent-deck";
    license = licenses.mit;
    mainProgram = "agent-deck";
    maintainers = [ ];
  };
}
