# DNS / Ad-blocking Migration

## Current Setup

- Pi-hole running for DNS-based ad blocking
- Port 53 (DNS)

## Migration

PLAN.md specifies Blocky instead of Pi-hole:
- Native NixOS module
- No containers/web UI complexity
- Simpler configuration

## NixOS Implementation

```nix
services.blocky = {
  enable = true;
  settings = {
    ports = {
      dns = 53;
      http = 4000;  # Optional API/metrics
    };

    upstream = {
      default = [
        "1.1.1.1"
        "8.8.8.8"
      ];
    };

    blocking = {
      blackLists = {
        ads = [
          "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
        ];
      };
      clientGroupsBlock = {
        default = [ "ads" ];
      };
    };

    # Cache
    caching = {
      minTime = "5m";
      maxTime = "30m";
    };
  };
};

networking.firewall.allowedUDPPorts = [ 53 ];
networking.firewall.allowedTCPPorts = [ 53 ];
```

## Router Configuration

Point your router's DHCP DNS server to the Pi's IP (192.168.0.198).

## Testing

```bash
dig @192.168.0.198 google.com
dig @192.168.0.198 ads.google.com  # Should be blocked
```
