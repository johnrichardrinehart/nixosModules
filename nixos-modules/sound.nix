{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.sound;
  highpassNode = {
    type = "builtin";
    name = "highpass";
    label = "bq_highpass";
    control = {
      "Freq" = cfg.rnnoise.highpass.frequency;
      "Q" = cfg.rnnoise.highpass.q;
    };
  };
  rnnoiseNode = {
    type = "ladspa";
    name = "rnnoise";
    plugin = "librnnoise_ladspa";
    label = "noise_suppressor_mono";
    control = {
      "VAD Threshold (%)" = cfg.rnnoise.vadThreshold;
      "VAD Grace Period (ms)" = cfg.rnnoise.vadGracePeriod;
      "Retroactive VAD Grace (ms)" = cfg.rnnoise.retroactiveVadGrace;
    };
  };
  deepfilterNode = {
    type = "ladspa";
    name = "deepfilter";
    plugin = "libdeep_filter_ladspa";
    label = "deep_filter_mono";
    control = {
      "Attenuation Limit (dB)" = cfg.rnnoise.deepfilter.attenuationLimit;
      "Min processing threshold (dB)" = cfg.rnnoise.deepfilter.minProcessingThreshold;
      "Max ERB processing threshold (dB)" = cfg.rnnoise.deepfilter.maxErbProcessingThreshold;
      "Max DF processing threshold (dB)" = cfg.rnnoise.deepfilter.maxDfProcessingThreshold;
      "Min Processing Buffer (frames)" = cfg.rnnoise.deepfilter.minProcessingBuffer;
      "Post Filter Beta" = cfg.rnnoise.deepfilter.postFilterBeta;
    };
  };
  deepfilterBeforeRnnoise = cfg.rnnoise.deepfilter.position == "beforeRnnoise";
  deepfilterAfterRnnoise = cfg.rnnoise.deepfilter.position == "afterRnnoise";
  rnnoiseNodes =
    lib.optionals cfg.rnnoise.highpass.enable [ highpassNode ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterBeforeRnnoise) [ deepfilterNode ]
    ++ [ rnnoiseNode ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterAfterRnnoise) [ deepfilterNode ];
  rnnoiseLinks =
    lib.optionals
      (cfg.rnnoise.highpass.enable && cfg.rnnoise.deepfilter.enable && deepfilterBeforeRnnoise)
      [
        {
          output = "highpass:Out";
          input = "deepfilter:Audio In";
        }
      ]
    ++
      lib.optionals
        (cfg.rnnoise.highpass.enable && (!cfg.rnnoise.deepfilter.enable || deepfilterAfterRnnoise))
        [
          {
            output = "highpass:Out";
            input = "rnnoise:Input";
          }
        ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterBeforeRnnoise) [
      {
        output = "deepfilter:Audio Out";
        input = "rnnoise:Input";
      }
    ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterAfterRnnoise) [
      {
        output = "rnnoise:Output";
        input = "deepfilter:Audio In";
      }
    ];
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
      vadThreshold = lib.mkOption {
        type = lib.types.float;
        default = 50.0;
        description = "RNNoise VAD threshold percentage.";
      };
      vadGracePeriod = lib.mkOption {
        type = lib.types.float;
        default = 500.0;
        description = "RNNoise VAD grace period in milliseconds.";
      };
      retroactiveVadGrace = lib.mkOption {
        type = lib.types.float;
        default = 100.0;
        description = "RNNoise retroactive VAD grace period in milliseconds.";
      };
      highpass = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a builtin PipeWire high-pass filter before RNNoise.";
        };
        frequency = lib.mkOption {
          type = lib.types.float;
          default = 120.0;
          description = "High-pass cutoff frequency in Hz when rnnoise.highpass.enable is true.";
        };
        q = lib.mkOption {
          type = lib.types.float;
          default = 0.707;
          description = "High-pass biquad Q value when rnnoise.highpass.enable is true.";
        };
      };
      deepfilter = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable DeepFilterNet in the virtual microphone filter chain.";
        };
        position = lib.mkOption {
          type = lib.types.enum [
            "beforeRnnoise"
            "afterRnnoise"
          ];
          default = "beforeRnnoise";
          description = "Place DeepFilterNet before or after RNNoise. The high-pass filter, when enabled, always remains first.";
        };
        attenuationLimit = lib.mkOption {
          type = lib.types.float;
          default = 100.0;
          description = "DeepFilterNet attenuation limit in dB.";
        };
        minProcessingThreshold = lib.mkOption {
          type = lib.types.float;
          default = -15.0;
          description = "DeepFilterNet minimum processing threshold in dB.";
        };
        maxErbProcessingThreshold = lib.mkOption {
          type = lib.types.float;
          default = 35.0;
          description = "DeepFilterNet maximum ERB processing threshold in dB.";
        };
        maxDfProcessingThreshold = lib.mkOption {
          type = lib.types.float;
          default = 35.0;
          description = "DeepFilterNet maximum deep-filter processing threshold in dB.";
        };
        minProcessingBuffer = lib.mkOption {
          type = lib.types.float;
          default = 0.0;
          description = "DeepFilterNet minimum processing buffer in frames.";
        };
        postFilterBeta = lib.mkOption {
          type = lib.types.float;
          default = 0.0;
          description = "DeepFilterNet post-filter beta.";
        };
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
      extraLadspaPackages = [
        pkgs.rnnoise-plugin.ladspa
      ]
      ++ lib.optionals cfg.rnnoise.deepfilter.enable [ pkgs.deepfilternet ];

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
                  "nodes" = rnnoiseNodes;
                }
                // lib.optionalAttrs (rnnoiseLinks != [ ]) { "links" = rnnoiseLinks; };
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
