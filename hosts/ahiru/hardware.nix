{ config, lib, pkgs, ... }:

{
  # Raspberry Pi 4
  raspberry-pi-nix.board = "bcm2711";

  # Root filesystem on USB HDD (sda1) - 30GB partition
  # mkForce required to override raspberry-pi-nix sd-image defaults
  fileSystems."/" = {
    device = lib.mkForce "/dev/disk/by-label/NIXOS_ROOT";
    fsType = lib.mkForce "ext4";
  };

  # Boot firmware partition on SD card (required for Pi bootloader)
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
  };

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
