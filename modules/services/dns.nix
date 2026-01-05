{ config, lib, pkgs, ... }:

{
  # ============================================================
  # Blocky - DNS ad-blocking (replaces Pi-hole)
  # ============================================================

  # Open DNS port
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [ 53 ];

  services.blocky = {
    enable = true;
    settings = {
      # Upstream DNS servers
      upstreams.groups.default = [
        "https://dns.cloudflare.com/dns-query"
        "https://dns.google/dns-query"
      ];

      # Bootstrap DNS (for resolving DoH hostnames)
      bootstrapDns = [
        { upstream = "1.1.1.1"; }
        { upstream = "8.8.8.8"; }
      ];

      # Listen on all interfaces for LAN clients
      ports = {
        dns = 53;
        http = 4000;  # API/metrics
      };

      # Ad-blocking lists
      blocking = {
        denylists = {
          ads = [
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
            "https://adaway.org/hosts.txt"
            "https://v.firebog.net/hosts/AdguardDNS.txt"
          ];
          malware = [
            "https://urlhaus.abuse.ch/downloads/hostfile/"
          ];
        };
        # Allowlist for false positives
        allowlists = {
          ads = [
            # Add any domains that get incorrectly blocked
          ];
        };
        clientGroupsBlock = {
          default = [ "ads" "malware" ];
        };
        # How to respond to blocked queries
        blockType = "zeroIp";
        # Refresh lists daily
        refreshPeriod = "24h";
      };

      # Caching
      caching = {
        minTime = "5m";
        maxTime = "30m";
        prefetching = true;
      };

      # Logging
      log.level = "info";
    };
  };
}
