{ config, lib, pkgs, ... }:

{
  # Enable audio (3.5mm headphone jack)
  boot.kernelParams = [
    "snd_bcm2835.enable_headphones=1"
    # Seagate Expansion (old disk, attached until unplugged): its UAS mode
    # rejects SMART (SAT) passthrough.
    "usb-storage.quirks=0bc2:231a:u"
  ];

  # CVE-2026-31431 ("Copy Fail") mitigation: block algif_aead until the
  # patched kernel lands in the channel. AF_ALG isn't used by SSH/TLS/LUKS.
  # `blacklist` alone won't stop the kernel's request_module() autoload from
  # AF_ALG socket(); the `install ... /bin/false` form is what actually blocks it.
  boot.blacklistedKernelModules = [ "algif_aead" ];
  boot.extraModprobeConfig = ''
    install algif_aead /bin/false
  '';

  # Root on the WD USB HDD, p1. By UUID, not label: the old Seagate still
  # carries NIXOS_ROOT while it's attached.
  # mkForce required to override the sd-image defaults (ahiru-base image)
  fileSystems."/" = {
    device = lib.mkForce "/dev/disk/by-uuid/e3d69c01-2dbf-4a80-916c-053884b8fead";
    fsType = lib.mkForce "ext4";
  };

  # U-Boot reads extlinux.conf and the generations' kernels from here. On the SD
  # card (not the USB HDD) because U-Boot's mmc support is the reliable path;
  # it carries the MBR bootable flag so U-Boot scans it rather than partition 1.
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXOS_BOOT";
    fsType = "ext4";
  };

  # Boot firmware partition on SD card (required for Pi bootloader)
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
  };

  # Data partition (WD p2) - DO NOT FORMAT
  # No nofail/short device-timeout: it holds /nix and is mounted (and fscked)
  # in stage 1, so stage 2's 10s device wait only produced a spurious
  # systemd-fsck "dependency failed" every boot.
  fileSystems."/media/data" = {
    device = "/dev/disk/by-uuid/bbc725b0-4d8f-4654-8d44-3feb0c1cd749";
    fsType = "ext4";
  };

  # No swap on flash storage - use zram instead
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  # Persistent logs on the USB-HDD root so crashes survive a reboot.
  # (Was volatile/tmpfs from the SD-card era; root now lives on an ext4
  # partition on the USB disk, where journal writes are cheap. Capped at 1G
  # (~30 days) so a log storm can't fill /.) Complemented by the per-minute black-box
  # recorder in modules/services/monitoring.nix.
  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=1G
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

  # The USB HDD (bridge queue depth 1) is saturated by rtorrent's random seed
  # reads. With the default nr_requests=2 every extra request blocks in
  # blk_mq_get_tag, so mq-deadline can't prefer MPD over rtorrent (IO class
  # idle, torrent.nix); 64 gives it a queue to reorder. APM off stops the
  # heads parking and unparking (audible clicks) on every seed read. Re-run on
  # every add so a USB re-enumeration doesn't revert the drive's APM.
  # read_ahead_kb 64 (default 512): seed peers ask for scattered 16K blocks,
  # and 512K readahead around each made the disk read ~4x what was uploaded.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_WWN}=="0x50014ee2172bd115", ATTR{queue/nr_requests}="64", ATTR{queue/read_ahead_kb}="64", RUN+="${pkgs.smartmontools}/bin/smartctl -d sat -s apm,off $devnode"
  '';

  # Use tmpfs for /tmp
  boot.tmp.useTmpfs = true;
}
