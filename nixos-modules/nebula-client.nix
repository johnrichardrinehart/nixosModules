{
  config,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.nebula.client;
  inherit (cfg) network;
  lighthouse = cfg.lighthouse.address;
  zone = "${network}.${cfg.parentDomain}";
  routedZones = lib.escapeShellArgs (
    map (domain: "~${domain}") (
      [
        zone
        "${network}.internal"
      ]
      ++ cfg.dnsAliases
    )
  );
  device =
    let
      configured = config.services.nebula.networks.${network}.tun.device;
    in
    if configured != null then configured else "nebula.${network}";
  toLighthouse = proto: port: {
    inherit port proto;
    cidr = "${lighthouse}/32";
  };
in
{
  options.dev.johnrinehart.nebula.client = {
    enable = lib.mkEnableOption "a Nebula overlay client that trusts only peers, never the lighthouse, for inbound traffic";
    network = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]{0,7}";
      example = "mycelium";
      description = ''
        Name of the Nebula network (the VPN). It names the tun device
        (`nebula.<network>`, so at most 8 characters), the systemd unit and
        the DNS zone `<network>.<parentDomain>`.
      '';
    };
    parentDomain = lib.mkOption {
      type = lib.types.str;
      default = "nebula.johnrinehart.dev";
      description = "Parent of every VPN's DNS zone.";
    };
    dnsAliases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "mycelium.internal" ];
      description = "Additional private DNS zones beyond the default `<network>.internal` alias.";
    };
    lighthouse = {
      address = lib.mkOption {
        type = lib.types.str;
        example = "10.77.0.1";
        description = "The lighthouse's overlay address; it also serves DNS and the peer site.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        example = "nebula-lighthouse.johnrinehart.dev:4242";
        description = "Public host:port of the lighthouse.";
      };
    };
    ca = lib.mkOption {
      type = lib.types.str;
      description = "Path to the CA certificate bundle (pki.ca).";
    };
    cert = lib.mkOption {
      type = lib.types.str;
      description = "Path to this host's certificate (pki.cert).";
    };
    key = lib.mkOption {
      type = lib.types.str;
      description = "Path to this host's private key (pki.key).";
    };
    peerGroup = lib.mkOption {
      type = lib.types.str;
      default = "peer";
      description = ''
        Certificate group that every non-lighthouse host carries. Inbound
        traffic is accepted only from this group, so the lighthouse, whose
        certificate lacks it, can never open a connection to this host.
      '';
    };
    inbound = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            port = lib.mkOption { type = lib.types.str; };
            proto = lib.mkOption {
              type = lib.types.enum [
                "any"
                "tcp"
                "udp"
                "icmp"
              ];
            };
          };
        }
      );
      default = [
        {
          port = "any";
          proto = "icmp";
        }
        {
          port = "22";
          proto = "tcp";
        }
      ];
      description = "Ports other peers may open on this host.";
    };
    peerSshPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "22" ];
      example = [
        "22"
        "8022"
      ];
      description = ''
        TCP ports this host may open on other peers (the peer group) for SSH.
        Android SSH servers such as Termux's listen on 8022 because apps
        cannot bind ports below 1024.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.nebula.networks.${network} = {
      inherit (cfg) ca cert key;
      lighthouses = [ lighthouse ];
      staticHostMap.${lighthouse} = [ cfg.lighthouse.endpoint ];
      listen.port = 0;
      # Peers reach this host through the lighthouse when NAT blocks a direct
      # tunnel; answer the lighthouse's punch notifications otherwise.
      relays = [ lighthouse ];
      settings.punchy = {
        punch = true;
        respond = true;
      };
      # Contact with the lighthouse is always initiated from this host; the
      # stateful firewall admits the replies. Peers may ping and SSH each
      # other; the lighthouse is not in the peer group, so it is never a target.
      firewall.outbound = [
        (toLighthouse "icmp" "any")
        (toLighthouse "tcp" "22")
        (toLighthouse "udp" "53")
        (toLighthouse "tcp" "53")
        (toLighthouse "tcp" "443")
        {
          port = "any";
          proto = "icmp";
          group = cfg.peerGroup;
        }
      ]
      ++ map (port: {
        inherit port;
        proto = "tcp";
        group = cfg.peerGroup;
      }) cfg.peerSshPorts;
      firewall.inbound = map (rule: rule // { group = cfg.peerGroup; }) cfg.inbound;
    };

    # Split DNS: only this VPN's zone goes to its lighthouse, over the tunnel.
    # Nebula signals readiness after creating its interface, and resolved
    # drops per-link settings when the interface goes away, so set them on
    # each start. `+` runs them as root: resolved refuses the unprivileged
    # Nebula service user.
    services.resolved.enable = true;
    systemd.services."nebula@${network}" = {
      # The lighthouse endpoint is usually a DNS name. Wait for a usable
      # network so Nebula can resolve it and reach the lighthouse at start.
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig.ExecStartPost =
        let
          resolvectl = "${config.systemd.package}/bin/resolvectl";
        in
        [
          "+${resolvectl} dns ${device} ${lighthouse}"
          "+${resolvectl} domain ${device} ${routedZones}"
          "+${resolvectl} default-route ${device} false"
        ];
    };
  };
}
