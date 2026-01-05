{ config, lib, pkgs, ... }:

{
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

    configText = ''
      # Instance layout
      method.insert = cfg.basedir,  private|const|string, (cat,"/media/data/Unsorted/")
      method.insert = cfg.download, private|const|string, (cat,(cfg.basedir),".downloading/")
      method.insert = cfg.logs,     private|const|string, (cat,(cfg.basedir),".log/")
      method.insert = cfg.session,  private|const|string, (cat,(cfg.basedir),".session/")
      method.insert = cfg.watch,    private|const|string, (cat,(cfg.basedir),".watch/")

      # Move completed downloads to category folder
      method.insert = d.get_finished_dir, simple, "cat=/media/data/Unsorted/,$d.custom1="
      method.insert = d.data_path, simple, "if=(d.is_multi_file), (cat,(d.directory),/), (cat,(d.directory),/,(d.name))"
      method.insert = d.move_to_complete, simple, "d.directory.set=$argument.1=; execute=mkdir,-p,$argument.1=; execute=mv,-u,$argument.0=,$argument.1=; d.save_full_session="
      method.set_key = event.download.finished,move_complete,"d.move_to_complete=$d.data_path=,$d.get_finished_dir="

      # Listening port
      network.port_range.set = 50000-50000
      network.port_random.set = no

      # DHT and peer exchange
      dht.mode.set = auto
      protocol.pex.set = yes
      trackers.use_udp.set = yes

      # Throttle settings
      throttle.global_down.max_rate.set_kb = 0
      throttle.global_up.max_rate.set_kb = 5200

      # Peer settings
      throttle.max_uploads.set = 100
      throttle.max_uploads.global.set = 250
      throttle.min_peers.normal.set = 20
      throttle.max_peers.normal.set = 60
      throttle.min_peers.seed.set = 30
      throttle.max_peers.seed.set = 80
      trackers.numwant.set = 80

      protocol.encryption.set = allow_incoming,try_outgoing,enable_retry

      # Resource limits
      network.http.max_open.set = 50
      network.max_open_files.set = 600
      network.max_open_sockets.set = 300
      pieces.memory.max.set = 1800M
      network.xmlrpc.size_limit.set = 4M

      # Operational settings
      encoding.add = utf8
      system.umask.set = 0027
      network.http.dns_cache_timeout.set = 25
      schedule2 = monitor_diskspace, 15, 60, ((close_low_diskspace, 1000M))

      # Watch directories
      schedule2 = watch_load, 11, 10, ((load.verbose, (cat, (cfg.watch), "load/*.torrent")))
      schedule2 = watch_start, 10, 10, ((load.start_verbose, (cat, (cfg.watch), "start/*.torrent")))

      # SCGI socket for Flood
      network.scgi.open_local = /run/rtorrent/rpc.socket
      schedule2 = socket_chmod, 0, 0, "execute=chmod,0660,/run/rtorrent/rpc.socket"
    '';
  };

  # Create watch directories
  systemd.tmpfiles.rules = [
    "d /media/data/Unsorted/.downloading 0775 torrents torrents -"
    "d /media/data/Unsorted/.session 0775 torrents torrents -"
    "d /media/data/Unsorted/.watch 0775 torrents torrents -"
    "d /media/data/Unsorted/.watch/load 0775 torrents torrents -"
    "d /media/data/Unsorted/.watch/start 0775 torrents torrents -"
    "d /media/data/Unsorted/.log 0775 torrents torrents -"
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
      ExecStart = "${pkgs.flood}/bin/flood --host 127.0.0.1 --port 3000 --rundir /var/lib/flood";
      Restart = "on-failure";
      StateDirectory = "flood";
    };
  };

  environment.systemPackages = [ pkgs.flood ];
}
