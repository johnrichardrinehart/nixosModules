{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.auto-suspend;
  sshSessionLockCfg = config.dev.johnrinehart.sshSessionLock;

  notificationIdsFile = "/var/lib/auto-suspend/notification-ids";

  dismissNotificationsScript = pkgs.writeShellScript "dismiss-auto-suspend-notifications" ''
    set -u

    ids_file=${lib.escapeShellArg notificationIdsFile}
    pending_file="$ids_file.pending"

    {
      ${pkgs.util-linux}/bin/flock 9 || exit 1
      [ -s "$ids_file" ] || exit 0
      : > "$pending_file"

      while read -r uid notification_id; do
        case "$uid" in
          "" | *[!0-9]*) continue ;;
        esac
        case "$notification_id" in
          "" | *[!0-9]*) continue ;;
        esac

        username=$(${pkgs.coreutils}/bin/id -un "$uid" 2>/dev/null || true)
        if [ -z "$username" ] || [ ! -S "/run/user/$uid/bus" ]; then
          printf '%s %s\n' "$uid" "$notification_id" >> "$pending_file"
          continue
        fi

        if ! DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
          ${pkgs.su}/bin/su -s ${pkgs.bash}/bin/sh "$username" -c \
          "${pkgs.systemd}/bin/busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications CloseNotification u $notification_id" \
          >/dev/null 2>&1; then
          printf '%s %s\n' "$uid" "$notification_id" >> "$pending_file"
        fi
      done < "$ids_file"

      if [ -s "$pending_file" ]; then
        ${pkgs.coreutils}/bin/mv "$pending_file" "$ids_file"
      else
        ${pkgs.coreutils}/bin/rm -f "$ids_file" "$pending_file"
      fi
    } 9>"$ids_file.lock"
  '';

  # Script to check battery and suspend if needed
  checkBatteryScript = import ./auto-suspend-check-battery.nix {
    inherit pkgs;
    inherit (cfg) lowLevel;
    inherit (cfg) criticalLevel;
    inherit (cfg) notificationLevels;
    inherit dismissNotificationsScript notificationIdsFile;
    confirmSshActivityCommand = lib.optionalString sshSessionLockCfg.enable (
      lib.getExe (
        pkgs.dev.johnrinehart.confirm-ssh-activity-before-suspend.override {
          promptTimeoutSeconds = sshSessionLockCfg.suspendPromptTimeoutSeconds;
        }
      )
    );
  };
in
{
  options.dev.johnrinehart.auto-suspend = {
    enable = lib.mkEnableOption "automatic battery-based suspend";

    lowLevel = lib.mkOption {
      type = lib.types.int;
      default = 15;
      description = ''
        Battery percentage at which to suspend (default: 15%).
        Internally converted to energy (Wh) based on battery capacity for more reliable detection.
        Also triggers when UPower reports 'low' capacity-level.
      '';
    };

    criticalLevel = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = ''
        Battery percentage at which to suspend-then-hibernate (default: 10%).
        Internally converted to energy (Wh) based on battery capacity for more reliable detection.
        Also triggers when UPower reports 'critical' capacity-level.
      '';
    };

    checkInterval = lib.mkOption {
      type = lib.types.str;
      default = "90s";
      description = "How often to check battery level (systemd timer format, default: 90s)";
    };

    notificationLevels = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [
        20
        15
        10
        5
      ];
      description = ''
        Battery percentage levels that send notifications (default: [20 15 10 5]).
        The module sends one notification for each level during a discharge cycle.
        It resets notified levels when charging starts.
        It dismisses active battery warnings after the system resumes.
      '';
      example = [
        30
        20
        15
        10
        5
        3
        1
      ];
    };

  };

  config = lib.mkIf cfg.enable {
    # Ensure upower is available
    services.upower.enable = true;

    # Create state directory
    systemd.tmpfiles.rules = [
      "d /var/lib/auto-suspend 0755 root root -"
    ];

    # Systemd service to check battery
    systemd.services.auto-suspend-check = {
      description = "Check battery level and auto-suspend if needed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${checkBatteryScript}";
        # Run as root to access systemctl suspend
        User = "root";
      };
    };

    # Keep the warning visible during sleep entry, then dismiss it after resume.
    systemd.services.auto-suspend-notification = {
      description = "Dismiss auto-suspend battery warnings after resume";
      wantedBy = [ "sleep.target" ];
      partOf = [ "sleep.target" ];
      before = [ "sleep.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = "${dismissNotificationsScript}";
        RemainAfterExit = true;
      };
    };

    # Timer to run the check periodically
    systemd.timers.auto-suspend-check = {
      description = "Timer for battery auto-suspend check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.checkInterval;
        Unit = "auto-suspend-check.service";
      };
    };
  };
}
