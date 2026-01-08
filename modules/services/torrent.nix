{ config, lib, pkgs, ... }:

{
  # rtorrent config uses 'sh' without full path - NixOS needs this symlink
  system.activationScripts.binsh = lib.stringAfter [ "stdio" ] ''
    mkdir -p /bin
    ln -sfn ${pkgs.bash}/bin/bash /bin/sh
  '';

  # Open port for incoming peer connections
  networking.firewall.allowedTCPPorts = [ 50000 ];

  # ============================================================
  # rtorrent - BitTorrent client
  # ============================================================
  services.rtorrent = {
    enable = true;
    user = "torrents";
    group = "torrents";
    dataDir = "/media/data/Unsorted";
    downloadDir = "/media/data/Unsorted/.downloading";
    port = 50000;
    openFirewall = false;  # We handle firewall above

    # Only add settings not provided by the NixOS module
    configText = ''
      # Override paths to use hidden directories (matching original config)
      session.path.set = /media/data/Unsorted/.session/
      log.open_file = "rtorrent", /media/data/Unsorted/.log/rtorrent.log
      log.add_output = "info", "rtorrent"

      # Watch directories for auto-loading torrents
      schedule2 = watch_start, 5, 5, "load.start=/media/data/Unsorted/.watch/start/*.torrent"
      schedule2 = watch_load, 6, 5, "load.normal=/media/data/Unsorted/.watch/load/*.torrent"

      # Enable DHT and peer exchange (module defaults to disabled)
      dht.mode.set = auto
      protocol.pex.set = yes
      trackers.use_udp.set = yes

      # Throttle settings
      throttle.global_down.max_rate.set_kb = 0
      throttle.global_up.max_rate.set_kb = 5200

      # Move completed downloads to category folder based on custom1 label
      method.insert = d.get_finished_dir, simple, "cat=/media/data/Unsorted/,$d.custom1="
      method.insert = d.data_path, simple, "if=(d.is_multi_file), (cat,(d.directory),/), (cat,(d.directory),/,(d.name))"
      method.insert = d.move_to_complete, simple, "d.directory.set=$argument.1=; execute=mkdir,-p,$argument.1=; execute=mv,-u,$argument.0=,$argument.1=; d.save_full_session="
      method.set_key = event.download.finished,move_complete,"d.move_to_complete=$d.data_path=,$d.get_finished_dir="
    '';
  };

  # Increase file descriptor limit for rtorrent (194 torrents * files per torrent)
  systemd.services.rtorrent.serviceConfig.LimitNOFILE = 65536;

  # Create hidden directories and remove non-hidden ones the NixOS module creates
  systemd.tmpfiles.rules = [
    "d /media/data/Unsorted/.downloading 0775 torrents torrents -"
    "d /media/data/Unsorted/.session 0775 torrents torrents -"
    "d /media/data/Unsorted/.watch 0775 torrents torrents -"
    "d /media/data/Unsorted/.log 0775 torrents torrents -"
    "r /media/data/Unsorted/session - - - -"
    "r /media/data/Unsorted/watch - - - -"
    "r /media/data/Unsorted/log - - - -"
  ];

  # ============================================================
  # Flood - Modern web UI for rtorrent
  # ============================================================
  systemd.services.flood = {
    description = "Flood torrent web UI";
    after = [ "rtorrent.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "torrents";
      Group = "torrents";
      ExecStart = "${pkgs.flood}/bin/flood --host 127.0.0.1 --port 3000 --baseuri /torrents --rundir /var/lib/flood --auth none --rtsocket /run/rtorrent/rpc.sock";
      Restart = "on-failure";
      StateDirectory = "flood";
    };
  };

  environment.systemPackages = [ pkgs.flood ];
}
