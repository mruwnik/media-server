{ config, lib, pkgs, ... }:

{
  # DHCP - router handles IP reservation
  networking.useDHCP = true;

  # Firewall
  networking.firewall = {
    enable = true;

    allowedTCPPorts = [
      22    # SSH
      80    # HTTP (certbot, redirect)
      443   # HTTPS
      # LAN services added by their modules:
      # 445 139 2049 - storage.nix
    ];

    allowedUDPPorts = [
      # 137 138 - storage.nix (NetBIOS)
    ];
  };
}
