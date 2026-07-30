{
  lib,
  buildGo126Module,
  fetchFromGitHub,
  git,
  tmux,
}:
buildGo126Module rec {
  pname = "agent-deck";
  version = "1.9.65";

  src = fetchFromGitHub {
    owner = "asheshgoplani";
    repo = "agent-deck";
    rev = "v${version}";
    hash = "sha256-WIifw8loi3/cE67KznpnxeoZYXCunnsyBHwHxidf1TU=";
  };

  vendorHash = "sha256-GyG71/iR2R4mq1vOYcL4rGXh0RQIMNeWj+WtjF75KCg=";

  subPackages = [ "cmd/agent-deck" ];

  nativeCheckInputs = [
    git
    tmux
  ];
  checkFlags = [
    # Keep the rest of the package tests enabled while skipping tests that
    # depend on interactive TUI timing.
    "-skip=TestLogCgroupIsolationDecision_WiredIntoBootstrap/tui_startup_emits_line"
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
