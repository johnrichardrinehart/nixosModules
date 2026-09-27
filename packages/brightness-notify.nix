{
  brightnessctl,
  coreutils,
  gnome-icon-theme,
  lib,
  libnotify,
  systemd,
  writeShellApplication,
}:

writeShellApplication {
  name = "brightness-notify";

  runtimeInputs = [
    brightnessctl
    coreutils
    libnotify
    systemd
  ];

  # The user-facing level is logical: 0-100 in 4% steps. The laptop backlight
  # and, through brightness-sync, external monitors' DDC/CI brightness follow
  # the level linearly. Below the knee a software factor applied to every
  # output through wl-gammarelay-rs falls linearly to zero, so software carries
  # more of the dimming as the level approaches 0.
  #
  # The factor is published at $XDG_RUNTIME_DIR/brightness-notify/software-brightness.
  # daylight-display multiplies it into its own brightness; when
  # daylight-display is not running, this script applies it directly.
  text = ''
    set -euo pipefail

    step=4
    knee=60

    action="''${1:-}"
    case "$action" in
      up | down | sync) ;;
      *)
        printf 'usage: brightness-notify up|down|sync\n' >&2
        exit 2
        ;;
    esac

    if ! status="$(brightnessctl --class=backlight --machine-readable info 2>/dev/null)"; then
      if [ "$action" = sync ]; then
        exit 0
      fi
      printf 'brightness-notify: no backlight device\n' >&2
      exit 1
    fi
    IFS=, read -r _device _class raw _percent max <<< "$status"
    nearest_step=$(( (200 * raw + step * max) / (2 * step * max) ))
    level=$(( nearest_step * step ))

    case "$action" in
      up)
        level=$(( level + step > 100 ? 100 : level + step ))
        title="Brightness up"
        ;;
      down)
        level=$(( level - step < 0 ? 0 : level - step ))
        title="Brightness down"
        ;;
    esac

    if [ "$action" != sync ]; then
      brightnessctl --class=backlight --quiet set "$level%"
    fi

    permille=$(( level >= knee ? 1000 : level * 1000 / knee ))
    factor="$(printf '%d.%03d' $(( permille / 1000 )) $(( permille % 1000 )))"

    state_dir="''${XDG_RUNTIME_DIR:?}/brightness-notify"
    mkdir -p "$state_dir"
    printf '%s\n' "$factor" > "$state_dir/software-brightness.tmp"
    mv -f "$state_dir/software-brightness.tmp" "$state_dir/software-brightness"

    if systemctl --user --quiet is-active daylight-display.service; then
      systemctl --user kill --kill-whom=main --signal=SIGUSR1 daylight-display.service \
        || printf 'brightness-notify: could not signal daylight-display\n' >&2
    elif busctl --user status rs.wl-gammarelay >/dev/null 2>&1; then
      busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Brightness d "$factor" \
        || printf 'brightness-notify: could not set software brightness\n' >&2
    fi

    if [ "$action" = sync ]; then
      exit 0
    fi

    if systemctl --user --quiet is-active brightness-sync.service; then
      systemctl --user kill --kill-whom=main --signal=SIGUSR1 brightness-sync.service \
        || printf 'brightness-notify: could not signal brightness-sync\n' >&2
    fi

    if [ "$level" -lt 25 ]; then
      icon="${gnome-icon-theme}/share/icons/gnome/48x48/status/stock_weather-night-clear.png"
      body="$level% - moonlit"
    elif [ "$level" -lt 75 ]; then
      icon="${gnome-icon-theme}/share/icons/gnome/48x48/status/weather-few-clouds-night.png"
      body="$level% - easy glow"
    else
      icon="${gnome-icon-theme}/share/icons/gnome/48x48/status/sunny.png"
      body="$level% - bright and clear"
    fi

    notify-send \
      --app-name="JohnOS Brightness" \
      --icon="$icon" \
      --expire-time=1400 \
      --hint=string:x-canonical-private-synchronous:brightness \
      --hint="int:value:$level" \
      "$title" \
      "$body" \
      || true
  '';

  meta = with lib; {
    description = "Adjust display brightness across backlight and software dimming and show an on-screen notification";
    license = licenses.mit;
    mainProgram = "brightness-notify";
    platforms = platforms.linux;
  };
}
