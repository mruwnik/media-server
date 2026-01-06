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
    ../../modules/services/media.nix
    ../../modules/services/calendar.nix
    ../../modules/services/git.nix
    ../../modules/services/dns.nix
    ../../modules/services/backup.nix
  ];
}
