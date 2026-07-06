{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.sound;
in
{
  options.dev.johnrinehart.sound = {
    enable = lib.mkEnableOption "John's sound config";

    rnnoise = {
      inputRules = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = ''
          WirePlumber monitor.alsa.rules entries used to rank or otherwise
          configure physical capture sources that can back rnnoise_source.

          The sound module intentionally leaves these host-specific. For
          example, a laptop configuration can prefer an external USB microphone
          over the built-in microphone by raising priority.session on matching
          Audio/Source nodes.
        '';
      };
    };

    debug = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable PipeWire debug logging via PIPEWIRE_DEBUG environment variable.";
      };
      level = lib.mkOption {
        type = lib.types.ints.between 0 5;
        default = 4;
        description = ''
          PipeWire log level: 0=none, 1=errors, 2=warnings, 3=info, 4=debug, 5=trace.
          Level 5 (trace) logs from realtime threads and will impact audio performance.
          Level 4 (debug) is the recommended maximum for ongoing use.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # PAM limits for the @audio group — foundation for realtime audio
    security.pam.loginLimits = [
      {
        domain = "@audio";
        type = "-";
        item = "memlock";
        value = "unlimited";
      }
      {
        domain = "@audio";
        type = "-";
        item = "rtprio";
        value = "95";
      }
      {
        domain = "@audio";
        type = "-";
        item = "nice";
        value = "-15";
      }
    ];

    services.pipewire = {
      enable = true;

      alsa.enable = true;
      alsa.support32Bit = false;
      pulse.enable = true;
      wireplumber = {
        enable = true;
        extraConfig = lib.mkIf (cfg.rnnoise.inputRules != [ ]) {
          "51-rnnoise-capture-source-policy" = {
            "monitor.alsa.rules" = cfg.rnnoise.inputRules;
          };
        };
      };
      extraLadspaPackages = [ pkgs.rnnoise-plugin.ladspa ];

      jack.enable = false;

      extraConfig.pipewire = {
        "10-low-latency" = {
          "context.properties" = {
            "default.clock.quantum" = 512;
            "default.clock.min-quantum" = 256;
            "default.clock.max-quantum" = 1024;
          };
        };

        # RNNoise noise suppression — replaces NoiseTorch.
        # Expose one stable virtual source. Its capture side autoconnects to
        # WirePlumber's preferred physical source. Host configurations can tune
        # that preference with dev.johnrinehart.sound.rnnoise.inputRules.
        "20-noise-suppression" = {
          "context.modules" = [
            {
              name = "libpipewire-module-filter-chain";
              flags = [ "nofail" ];
              args = {
                "node.description" = "Noise Canceled Microphone";
                "media.name" = "Noise Canceled Microphone";
                "audio.position" = [ "MONO" ];
                "filter.graph" = {
                  "nodes" = [
                    {
                      type = "ladspa";
                      name = "rnnoise";
                      plugin = "librnnoise_ladspa";
                      label = "noise_suppressor_mono";
                      control = {
                        "VAD Threshold (%)" = 50.0;
                      };
                    }
                  ];
                };
                "capture.props" = {
                  "node.name" = "capture.rnnoise";
                  "node.passive" = true;
                  "audio.rate" = 48000;
                };
                "playback.props" = {
                  "node.name" = "rnnoise_source";
                  "node.description" = "Noise Canceled Microphone";
                  "media.class" = "Audio/Source";
                  "audio.rate" = 48000;
                };
              };
            }
          ];
        };

        # Loopback for hearing your own mic through headphones (via noise suppression)
        "30-mic-monitor" = {
          "context.modules" = [
            {
              name = "libpipewire-module-loopback";
              args = {
                "capture.props" = {
                  "node.name" = "mic-monitor-capture";
                  "node.description" = "Mic Monitor";
                  "node.passive" = true;
                  "target.object" = "rnnoise_source";
                  "audio.position" = [ "MONO" ];
                };
                "playback.props" = {
                  "node.name" = "mic-monitor-playback";
                  "node.description" = "Mic Monitor";
                  "audio.position" = [
                    "FL"
                    "FR"
                  ];
                };
              };
            }
          ];
        };
      };
    };

    # Allow the systemd user manager to grant realtime priority and memlock
    # to child services. user@.service doesn't go through PAM, so the
    # security.pam.loginLimits for @audio don't apply here.
    systemd.services."user@".serviceConfig = {
      LimitRTPRIO = 95;
      LimitNICE = "-15";
      LimitMEMLOCK = "infinity";
    };

    # Harden PipeWire against swap and resource starvation
    systemd.user.services.pipewire.serviceConfig = lib.mkMerge [
      {
        LimitMEMLOCK = "infinity";
        LimitRTPRIO = 95;
        OOMScoreAdjust = -500;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 0;
        Nice = -11;
        MemorySwapMax = "0";
        LockPersonality = true;
      }
      (lib.mkIf cfg.debug.enable {
        Environment = [ "PIPEWIRE_DEBUG=${toString cfg.debug.level}" ];
      })
    ];

    systemd.user.services.wireplumber.serviceConfig = {
      LimitMEMLOCK = "infinity";
      LimitRTPRIO = 95;
      OOMScoreAdjust = -500;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 0;
      Nice = -11;
      MemorySwapMax = "0";
    };

  };
}
