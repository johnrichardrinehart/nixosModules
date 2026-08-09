{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.repo-manager;
  primaryUser = config.dev.johnrinehart.users.primary;
  format = pkgs.formats.json { };
  configFile = format.generate "repo-manager-config.json" cfg.settings;
in
{
  options.dev.johnrinehart.repo-manager = {
    enable = lib.mkEnableOption "repo-manager configuration";

    package = lib.mkPackageOption pkgs.dev.johnrinehart "repo-manager" { };

    settings = lib.mkOption {
      inherit (format) type;
      default = {
        cache_root = "/home/${primaryUser}/.cache/repo-manager";
        auto_create_remote = false;
        clone_as_bare = true;
        config_version = 1;
        clone_start_ttl_minutes = 60;
        detect_related = true;
        root = "/home/${primaryUser}/code";
        rpc_rate_limit_per_second = 1;
        state = "/home/${primaryUser}/.local/state/repo-manager/repos.sqlite";
      };
      description = ''
        repo-manager JSON configuration written to
        ~/.config/repo-manager/config.json for the primary user.
      '';
    };

    daemon = {
      enable = lib.mkEnableOption "the repo-manager user daemon";
      package = lib.mkPackageOption pkgs.dev.johnrinehart "repod" { };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ]
    ++ lib.optional cfg.daemon.enable cfg.daemon.package;

    home-manager.users.${primaryUser} = {
      xdg.configFile."repo-manager/config.json".source = configFile;

      # Git stores repo-manager fork branches under custom refs, so Oh My Zsh
      # cannot show their short names. Add the display fix only with Oh My Zsh.
      programs.zsh.initContent =
        lib.mkIf config.home-manager.users.${primaryUser}.programs.zsh.oh-my-zsh.enable
          (
            lib.mkAfter ''
              # Preserve glg's git log --stat behavior and label ref kinds
              # so namespaces and remotes remain distinct.
              unalias glg 2>/dev/null || true
              glg() {
                local color=never
                local branch_color=""
                local namespace_color=""
                local remote_color=""
                local -a pager
                if [[ -t 1 ]]; then
                  color=always
                  branch_color=$(git config --get-color color.decorate.branch 'green bold')
                  namespace_color=$(git config --get-color color.decorate.branch 'green bold')
                  remote_color=$(git config --get-color color.decorate.remoteBranch 'cyan')
                  pager=(less -R)
                else
                  pager=(cat)
                fi

                git log --stat --color="$color" --decorate=full \
                  --decorate-refs='refs/*' "$@" |
                  sed -E \
                    -e "s#refs/namespaces/([^/]+)/refs/heads/#''${namespace_color}namespace/\\1/#g" \
                    -e "s#refs/repo-manager/[^[:space:],)]*/remotes/([^/]+)/#''${remote_color}remote/fork/\\1/#g" \
                    -e "s#refs/repo-manager/[^[:space:],)]*/heads/#''${namespace_color}namespace/fork/#g" \
                    -e "s#refs/remotes/([^/]+)/#''${remote_color}remote/\\1/#g" \
                    -e "s#refs/heads/#''${branch_color}#g" \
                    -e "s#refs/tmp/#''${namespace_color}namespace/tmp/#g" |
                  "''${pager[@]}"
              }
            ''
          );

      systemd.user.services.repod = lib.mkIf cfg.daemon.enable {
        Unit = {
          Description = "repo-manager RPC daemon";
        };

        Service = {
          ExecStart = lib.getExe cfg.daemon.package;
          Restart = "on-failure";
        };

        Install.WantedBy = [ "default.target" ];
      };
    };
  };
}
