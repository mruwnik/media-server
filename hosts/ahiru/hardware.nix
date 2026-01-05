{ config, lib, pkgs, ... }:

{
  # Raspberry Pi 4
  raspberry-pi-nix.board = "bcm2711";

  # Root filesystem - commented out for SD image build
  # The sd-image module sets root to NIXOS_SD label
  # Uncomment and adjust when installing to USB (sda1):
  # fileSystems."/" = {
  #   device = "/dev/disk/by-uuid/b0b6ea33-0881-4c39-a87f-f962c15cd6ad";
  #   fsType = "ext4";
  # };

  # Existing data partition - DO NOT FORMAT
  # nofail so SD-only boot works without the HDD
  fileSystems."/media/data" = {
    device = "/dev/disk/by-uuid/1934daec-232f-41f6-b6b8-107923b3fd1e";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10" ];
  };

  # No swap on flash storage - use zram instead
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  # Reduce writes - logs to tmpfs
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=64M
  '';

  # Use tmpfs for /tmp
  boot.tmp.useTmpfs = true;
}
