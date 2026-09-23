{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.programs.git.hostFsmonitor;
  primaryUser = config.dev.johnrinehart.users.primary;
  userGit = config.home-manager.users.${primaryUser}.programs.git.package;

  # oh-my-pi runs every git it spawns with fsmonitor and the untracked cache
  # pinned off (`hardened_args` in crates/pi-vcs/src/git/cli.rs), and its
  # status line reruns `git status` a second after each one finishes. Under a
  # share that is a host lstat per index entry, over and over, which is the
  # scan the hook exists to avoid. Its status is a lock-free read
  # (`--no-optional-locks`, and GIT_OPTIONAL_LOCKS=0 in its environment), so
  # honouring the hook and the cache there writes nothing back to the index.
  # Only that exact argv loses the two pins; anything else, including every
  # other git oh-my-pi runs, passes through untouched. Should oh-my-pi change
  # the layout, the match simply fails and its status scans as before.
  ompStatusGit = pkgs.writeShellScriptBin "git" ''
    if [[ $# -ge 6 && $1 == -c && $2 == core.fsmonitor=false && $3 == -c &&
      $4 == core.untrackedCache=false && $5 == --no-optional-locks && $6 == status ]]; then
      shift 4
    fi
    exec ${lib.getExe' userGit "git"} "$@"
  '';
in
{
  options.dev.johnrinehart.programs.git.hostFsmonitor = {
    enable = lib.mkEnableOption "answering git's fsmonitor queries from a watchman on this guest's host";

    package = lib.mkPackageOption pkgs.dev.johnrinehart "git-fsmonitor-host-watchman" { };

    manifest = lib.mkOption {
      type = lib.types.str;
      default = "/run/vm-shares/manifest.json";
      description = ''
        The shares manifest the launcher exports into the guest. The hook reads
        the guest-to-host path mapping from its `shares` and the bridge address
        from its `watchman` entry.
      '';
    };

    roots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ config.dev.johnrinehart.repo-manager.settings.root ];
      defaultText = lib.literalExpression "[ config.dev.johnrinehart.repo-manager.settings.root ]";
      description = ''
        Directories under which repositories use the hook, as `gitdir:` include
        conditions. A repository elsewhere keeps git's default scan; the hook
        would only refuse it for not being under a share.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home-manager.users.${primaryUser} = {
      programs.git.includes = map (root: {
        condition = "gitdir:${root}/**";
        contentSuffix = "host-fsmonitor.gitconfig";
        contents.core = {
          fsmonitor = "VM_SHARES_MANIFEST=${lib.escapeShellArg cfg.manifest} ${lib.getExe cfg.package}";
          # With fsmonitor vouching that a directory is unchanged, the untracked
          # cache lets git skip reading it too; without this the readdirs
          # remain, and on a share each of those is a host lstat per entry.
          untrackedCache = true;
          # Git otherwise retries a failed hook with protocol version 1, which
          # the hook then rejects too: two complaints per status for one cause.
          fsmonitorHookVersion = 2;
          # The host's git and this guest's share each worktree's index, and
          # see different uids, gids and inode numbers for the same files: the
          # 9p server's multidevs=remap renumbers every inode, and an account
          # renumbered since an index was written carries its old uid in it.
          # Under the default checkStat any of those mismatches makes git
          # re-read and re-hash the file, on every status that cannot write the
          # index back and on the first one after the other side wrote it.
          # minimal leaves whole-second mtime, size (and ctime) to decide.
          checkStat = "minimal";
        };
      }) cfg.roots;

      # Shadows programs.git's own bin/git in the profile; the rest of that
      # package (libexec, completions, man pages) still comes from it.
      home.packages = [ (lib.hiPrio ompStatusGit) ];
    };
  };
}
