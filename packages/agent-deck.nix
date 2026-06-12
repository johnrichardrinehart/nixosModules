{
  lib,
  buildGo126Module,
  fetchFromGitHub,
  git,
  tmux,
}:
buildGo126Module rec {
  pname = "agent-deck";
  version = "1.9.57";

  src = fetchFromGitHub {
    owner = "asheshgoplani";
    repo = "agent-deck";
    rev = "v${version}";
    hash = "sha256-Pn+OVshqc0bZNr4ClYx6JtWQk0YZFjxwZNnBM7CB3Xg=";
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
