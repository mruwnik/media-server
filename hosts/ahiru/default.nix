# Full configuration - imports base + all services
# Build base image: nix build '.#images.ahiru-base'
# Apply full config: sudo nixos-rebuild switch --flake '.#ahiru'
{ config, pkgs, inputs, ... }:

{
  imports = [
    ./base.nix
    # Services
    ../../modules/services/nginx.nix
    ../../modules/services/websites.nix
    ../../modules/services/storage.nix
    ../../modules/services/torrent.nix
    ../../modules/services/rtorrent-curl8-pin.nix  # TEMP pin — remove when libtorrent#722/#756 fixed
    ../../modules/services/media.nix
    ../../modules/services/calendar.nix
    ../../modules/services/git.nix
    ../../modules/services/dns.nix
    ../../modules/services/backup.nix
    ../../modules/services/mcp.nix
    ../../modules/services/mail.nix
    ../../modules/services/updates.nix
    ../../modules/services/monitoring.nix
    ../../modules/services/mpd-rating.nix
  ];

  # 26.05 flipped this default to true. Adopting systemd stage 1 is not something
  # to do as a side effect of a channel bump: /nix is a bind mount off the USB HDD
  # that has to come up in the initrd, and getting it wrong means a headless box
  # that won't boot. (It also drags in the TPM2 stage-1 block, which requires
  # tpm-crb/tpm-tis — modules the rpi kernel doesn't build.)
  boot.initrd.systemd.enable = false;

  # buildEnv pulls each systemPackages entry's `doc` attr into system-path, and
  # python312's is a Sphinx build that fails against docutils 0.22.4. Nothing
  # reads share/doc on a headless box; manpages are unaffected.
  documentation.doc.enable = false;

  # Move /nix to the 4.5TB data partition — the 30GB root partition is too
  # small for nix store growth during updates. The data partition must mount
  # in the initrd (neededForBoot) so /nix is available before stage 2 init.
  # base.nix keeps /media/data as nofail so SD-only recovery boots still work.
  fileSystems."/media/data".neededForBoot = true;
  fileSystems."/nix" = {
    device = "/media/data/nix";
    fsType = "none";
    options = [ "bind" ];
    neededForBoot = true;
  };
}
