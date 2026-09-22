{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.programs.git.hostFsmonitor;
  primaryUser = config.dev.johnrinehart.users.primary;
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
    home-manager.users.${primaryUser}.programs.git.includes = map (root: {
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
      };
    }) cfg.roots;
  };
}
