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

      # Local override: LAN clients must reach media.ahiru.pl directly —
      # the router masquerades hairpinned traffic as the WAN IP, which
      # defeats nginx's `allow 192.168.0.0/24` (satisfy any) on /files/.
      customDNS = {
        customTTL = "1h";
        mapping = {
          "media.ahiru.pl" = "192.168.0.198";
        };
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
