{ config, lib, pkgs, ... }:

{
  # Raspberry Pi 4
  raspberry-pi-nix.board = "bcm2711";

  # Enable audio (3.5mm headphone jack)
  # Note: also need dtparam=audio=on in /boot/firmware/config.txt
  boot.kernelParams = [
    "snd_bcm2835.enable_headphones=1"
  ];

  # CVE-2026-31431 ("Copy Fail") mitigation: block algif_aead until the
  # patched kernel lands in the channel. AF_ALG isn't used by SSH/TLS/LUKS.
  # `blacklist` alone won't stop the kernel's request_module() autoload from
  # AF_ALG socket(); the `install ... /bin/false` form is what actually blocks it.
  boot.blacklistedKernelModules = [ "algif_aead" ];
  boot.extraModprobeConfig = ''
    install algif_aead /bin/false
  '';

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

  # Persistent logs on the USB-HDD root so crashes survive a reboot.
  # (Was volatile/tmpfs from the SD-card era; root now lives on a 30GB ext4
  # partition on the USB disk, where journal writes are cheap. Capped at 500M
  # so a log storm can't fill /.) Complemented by the per-minute black-box
  # recorder in modules/services/monitoring.nix.
  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=500M
    SystemMaxFileSize=50M
    RuntimeMaxUse=64M
  '';

  # When the USB disk stalls, tasks pile up in uninterruptible sleep (D-state)
  # and the box wedges with no trace. Lower the hung-task warning threshold and
  # never stop warning, so a stalled task dumps its kernel stack into the
  # now-persistent journal. Warn-only: hung_task_panic stays 0 (no auto-reboot).
  boot.kernel.sysctl = {
    "kernel.hung_task_timeout_secs" = 60;
    "kernel.hung_task_warnings" = -1;
  };

  # Use tmpfs for /tmp
  boot.tmp.useTmpfs = true;
}
