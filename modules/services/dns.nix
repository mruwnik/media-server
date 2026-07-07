{ config, lib, pkgs, ... }:

{
  # ============================================================
  # Blocky - DNS ad-blocking (replaces Pi-hole)
  # ============================================================

  # Allowlist file for domains that shouldn't be blocked
  environment.etc."blocky/allowlist.txt".text = ''
    # Filen cloud backup (WebDAV)
    webdav.filen.io
  '';

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

      # Split-horizon: on the LAN, ahiru.pl (and subdomains) is the Pi itself,
      # not the WAN IP — the router doesn't hairpin non-forwarded ports, so
      # LAN-only services (differ :8576) are unreachable via the public A
      # record. Other record types for the domain are filtered, not forwarded
      # (blocky's default), so no public AAAA can leak a WAN path back in.
      customDNS.mapping."ahiru.pl" = "192.168.0.198";

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
            "/etc/blocky/allowlist.txt"
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
