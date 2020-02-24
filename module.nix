{ config, lib, pkgs, ... }:

with lib;
with builtins;

let
  cfg = config.services.zerotierone-with-dns;

  coredns = pkgs.callPackage ./coredns.nix { };
  dnscrypt-proxy = pkgs.callPackage ./dnscrypt-proxy.nix { };

  coredns-zt = pkgs.callPackage ./. {
    zerotierone = config.services.zerotierone.package;
  };

  zt-networks = lib.mapAttrsToList (_: v: v) cfg.networks;

  zt-dnscrypt-port = cfg.dnscryptPort;

  network-string = lib.concatStringsSep " " (lib.mapAttrsToList (z: n: "${z}:${n}") cfg.networks);

  zt-coredns-services = {

    # Initialize the DNS files that are always needed by other services.
    # This avoids tricky service ordering dependencies.
    zt-dns-init = {
      description = "setup ZeroTier DNS files";
      script = ''
        mkdir -p /etc/coredns-zt/
        touch /etc/coredns-zt/dns-blacklist.txt
        touch /etc/coredns-zt/hosts
      '';
      serviceConfig.Type = "oneshot";
    };

    # dnscrypt-proxy. This service handles requests going back to upstream
    # resolvers when they're not part of the ZeroTier network. It also
    # sinkholes bad domains and uses random upstream dnscrypt-enabled resolvers
    # as well.
    zt-dnscrypt =
      let
        dnscrypt-config = if cfg.dnscryptConfig != null
        then cfg.dnscryptConfig
        else pkgs.runCommand "dnscrypt-proxy.toml" {} ''
          substitute ${./dnscrypt-proxy.toml.in} $out \
          --subst-var-by PORT '${toString zt-dnscrypt-port}' \
        '';
      in {
        description = "dnscrypt-proxy2 service backend for CoreDNS";

        script = ''
          exec ${dnscrypt-proxy}/bin/dnscrypt-proxy -config ${dnscrypt-config}
        '';

        serviceConfig = {
          NoNewPrivileges = true;
          DynamicUser = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHome = true;
          ProtectSystem = true;

          LimitNPROC = 512;
          LimitNOFILE = 1048576;
          ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
          Restart = "on-failure";
        };

        requires = [ "network-online.target" "zt-dns-init.service" ];
        after    = [ "network-online.target" "zt-dns-init.service" ];
      };

    # CoreDNS. This service handles all incoming DNS requests and effectively
    # acts like a proxy to direct them to the correct host, or upstream
    # resolver. ZeroTier network members are handled by a hosts file, while all
    # other names are forwarded to dnscrypt-proxy.
    zt-coredns = {
      description = "CoreDNS service for ZeroTier networks";

      preStart = ''
        ${coredns-zt}/bin/zt2corefile ${toString cfg.port} ${network-string} > \
          /etc/coredns-zt/Corefile
        echo Corefile setup complete
      '';

      requires = [ "zerotierone.service" "zt-dnscrypt.service" "zt-dns-init.service" ];
      after    = [ "zerotierone.service" "zt-dnscrypt.service" "zt-dns-init.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        CapabilityBoundingSet = "cap_net_bind_service";
        AmbientCapabilities = "cap_net_bind_service";
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = true;
        PrivateTmp = true;
        DynamicUser = true;
        ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
        ExecStart  = "${coredns}/bin/coredns -conf /etc/coredns-zt/Corefile";
        Restart = "on-failure";
      };
    };

    # Timed service: update the list of ZeroTier network members in the 'hosts'
    # file for our private domains. Runs once a minute. NOTE: Requires CoreDNS,
    # because 'zt2hosts' needs it to resolve my.zerotier.com!
    zt-dns-update-hosts = {
      description = "hosts(5) update for ZeroTier DNS";
      startAt = "minutely";

      script = ''
        echo updating ZeroTier DNS hosts file...
        ${coredns-zt}/bin/zt2hosts ${network-string} > /tmp/hosts
        mv /tmp/hosts /etc/coredns-zt/hosts
        echo OK, done
      '';

      unitConfig.ConditionPathExists = "/etc/coredns-zt/api-token";
      serviceConfig = {
        PrivateTmp = true;
        EnvironmentFile = "/etc/coredns-zt/api-token";
      };

      requires = [ "zt-coredns.service" ];
      after    = [ "zt-coredns.service" ];
    };

    # Timed service: update the DNS blacklist from the upstream copy, once a
    # day. NOTE: requires CoreDNS, because curl needs it to resolve the name,
    # and we set the resolver to 127.0.0.1!
    zt-dns-update-blacklist = {
      description = "daily dnscrypt-proxy2 blacklist update";
      startAt = "daily";

      path = [ pkgs.curl ];
      script = ''
        echo Downloading blacklist...
        curl -s -o /tmp/dns-blacklist-new.txt \
          https://download.dnscrypt.info/blacklists/domains/mybase.txt
        mv /tmp/dns-blacklist-new.txt /etc/coredns-zt/dns-blacklist.txt
        echo OK
      '';

      serviceConfig = {
        PrivateTmp = true;
      };

      requires = [ "zt-coredns.service" ];
      after    = [ "zt-coredns.service" ];
    };
  };
in
{
  options.services.zerotierone-with-dns = {
    enable = mkEnableOption "Private DNS for your ZeroTier One Network";

    port = mkOption {
      type        = types.int;
      default     = 53;
      example     = 53;
      description = "Port for DNS requests";
    };

    dnscryptPort = mkOption {
      type        = types.int;
      default     = 1053;
      example     = 1053;
      description = "Port for dnscrypt";
    };

    dnscryptConfig = mkOption {
      type        = types.path;
      default     = null;
      description = "Path to dnscrypt-config.toml. If null the default template will be used.";
    };

    networks = mkOption {
      type        = types.attrsOf types.str;
      default     = {};
      example     = {
        "home-network.zt" = "...";
      };
      description = "Mapping of ZeroTier One networks to private DNS names";
    };
  };

  config = lib.mkIf cfg.enable {
    # We always enable ZeroTier one and pull the list of network IDs from it.
    services.zerotierone = {
      enable = true;
      joinNetworks = zt-networks;
    };

    # Punch open the firewall.
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    networking.firewall.allowedUDPPorts = [ cfg.port ];

    # Set the nameserver to localhost; this overrides everything since DNScrypt
    # does the rest. It might be nice to add an option for including an extra
    # list of servers if you want in DNSCrypt...
    networking.nameservers = [ "127.0.0.1" ];

    # Now pull in all the services.
    systemd.services = zt-coredns-services;
  };
}
