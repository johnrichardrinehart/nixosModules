{ fetchFromGitHub, tmux }:

tmux.overrideAttrs (
  finalAttrs: _old: {
    version = "3.7c";

    src = fetchFromGitHub {
      owner = "tmux";
      repo = "tmux";
      tag = finalAttrs.version;
      hash = "sha256-TpZXTeXKQv6MV1vAPu5MIT52d3Pl6dYcOReZa7QANZY=";
    };

    # 3.7c contains upstream e5a2a25 (patched into 3.6a by nixpkgs) and 31c93c4,
    # both fixes for partially initialized control-mode clients.
    patches = [ ];
  }
)
