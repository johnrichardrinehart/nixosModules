{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.kitkat-rs;
  variants = {
    fastest = pkgs.dev.johnrinehart.kitkat-rs-fastest;
    low-rss = pkgs.dev.johnrinehart.kitkat-rs-low-rss;
  };
in
{
  options.dev.johnrinehart.kitkat-rs = {
    enable = lib.mkEnableOption "Kitty-protocol terminal image rendering" // {
      default = config.dev.johnrinehart.packages.shell.enable;
      defaultText = lib.literalExpression "config.dev.johnrinehart.packages.shell.enable";
      description = ''
        Whether to install kitkat-rs system-wide. Enabled by default with the
        system shell-tool bundle so it is available locally and over SSH.
      '';
    };

    variant = lib.mkOption {
      type = lib.types.enum [
        "low-rss"
        "fastest"
      ];
      default = "low-rss";
      description = ''
        Implementation to install. low-rss streams non-interlaced PNG rows and
        minimizes memory use; fastest uses a full-frame, parallel resize path.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = variants.${cfg.variant};
      defaultText = lib.literalExpression "pkgs.dev.johnrinehart.kitkat-rs-${config.dev.johnrinehart.kitkat-rs.variant}";
      description = "kitkat-rs package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
