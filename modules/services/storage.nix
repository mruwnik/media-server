{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;
  primaryUid = config.ahiru.primaryUser.uid;
in
{
  # Firewall ports for file sharing
  networking.firewall = {
    allowedTCPPorts = [
      445   # SMB
      139   # NetBIOS Session
      2049  # NFS
    ];
    allowedUDPPorts = [
      137   # NetBIOS Name
      138   # NetBIOS Datagram
    ];
  };

  # ============================================================
  # Samba - Windows file sharing
  # ============================================================
  services.samba = {
    enable = true;
    openFirewall = false;  # We handle firewall above

    settings = {
      global = {
        workgroup = "AHIRU";
        "server string" = "ahiru";
        "netbios name" = "ahiru";

        # Security
        "security" = "user";
        "map to guest" = "bad user";
        "guest account" = "nobody";

        # Performance
        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY";
        "use sendfile" = "yes";
        "aio read size" = "16384";
        "aio write size" = "16384";
        "min receivefile size" = "16384";

        # Disable printing
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";

        # macOS compatibility
        "fruit:aapl" = "yes";
        "vfs objects" = "fruit streams_xattr";
      };

      # Media shares - read-only, authenticated
      Films = {
        path = "/media/data/Films";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "${primaryUser} nadia rumun";
      };

      Anime = {
        path = "/media/data/Anime";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "${primaryUser} nadia rumun";
      };

      Serials = {
        path = "/media/data/Serials";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "${primaryUser} nadia rumun";
      };

      Music = {
        path = "/media/data/Music";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "${primaryUser} nadia rumun";
      };

      Books = {
        path = "/media/data/Books";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "${primaryUser} nadia rumun";
      };

      # Unsorted - read-write for uploads
      Unsorted = {
        path = "/media/data/Unsorted";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "valid users" = "${primaryUser} nadia";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "torrents";
        "force group" = "torrents";
      };
    };
  };

  # Samba user/group (set password with: sudo smbpasswd -a <username>)
  users.groups.samba-users = {};

  # ============================================================
  # NFS - Network filesystem for LAN clients
  # ============================================================

  # Bind mounts for NFS exports (NFSv4 pseudo-filesystem)
  fileSystems."/export/Films" = {
    device = "/media/data/Films";
    fsType = "none";
    options = [ "bind" ];
  };
  fileSystems."/export/Anime" = {
    device = "/media/data/Anime";
    fsType = "none";
    options = [ "bind" ];
  };
  fileSystems."/export/Serials" = {
    device = "/media/data/Serials";
    fsType = "none";
    options = [ "bind" ];
  };
  fileSystems."/export/Music" = {
    device = "/media/data/Music";
    fsType = "none";
    options = [ "bind" ];
  };
  fileSystems."/export/Books" = {
    device = "/media/data/Books";
    fsType = "none";
    options = [ "bind" ];
  };
  fileSystems."/export/Unsorted" = {
    device = "/media/data/Unsorted";
    fsType = "none";
    options = [ "bind" ];
  };
  fileSystems."/export/${primaryUser}-backup" = {
    device = "/media/data/backups/${primaryUser}";
    fsType = "none";
    options = [ "bind" ];
  };
  fileSystems."/export/nadia" = {
    device = "/media/data/backups/nadia";
    fsType = "none";
    options = [ "bind" ];
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      # NFSv4 pseudo-filesystem root
      /export               192.168.0.0/24(ro,fsid=0,no_subtree_check,crossmnt)

      # Media - read-only
      /export/Films         192.168.0.0/24(ro,no_subtree_check,insecure)
      /export/Anime         192.168.0.0/24(ro,no_subtree_check,insecure)
      /export/Serials       192.168.0.0/24(ro,no_subtree_check,insecure)
      /export/Music         192.168.0.0/24(ro,no_subtree_check,insecure)
      /export/Books         192.168.0.0/24(ro,no_subtree_check,insecure)

      # Unsorted - read-write (torrent downloads)
      /export/Unsorted      192.168.0.0/24(rw,no_subtree_check,insecure,all_squash,anonuid=1001,anongid=1001)

      # Backups - read-write
      /export/${primaryUser}-backup    192.168.0.0/24(rw,no_subtree_check,insecure,all_squash,anonuid=${toString primaryUid},anongid=${toString primaryUid})
      /export/nadia         192.168.0.0/24(rw,no_subtree_check,insecure)
    '';
  };

  # Create export directories and manage /media/data ownership
  systemd.tmpfiles.rules = [
    # NFS export mount points
    "d /export 0755 root root -"
    "d /export/Films 0755 root root -"
    "d /export/Anime 0755 root root -"
    "d /export/Serials 0755 root root -"
    "d /export/Music 0755 root root -"
    "d /export/Books 0755 root root -"
    "d /export/Unsorted 0775 torrents users -"
    "d /export/${primaryUser}-backup 0755 root root -"
    "d /export/nadia 0755 root root -"

    # Media directories - primaryUser:users owns most, torrents:users owns Unsorted
    # 'd' creates if missing, 'z' sets ownership on existing directories
    "d /media/data 0755 ${primaryUser} users -"
    "z /media/data 0755 ${primaryUser} users -"
    "d /media/data/Anime 0755 ${primaryUser} users -"
    "z /media/data/Anime 0755 ${primaryUser} users -"
    "d /media/data/Audio 0755 ${primaryUser} users -"
    "z /media/data/Audio 0755 ${primaryUser} users -"
    "d /media/data/Books 0755 ${primaryUser} users -"
    "z /media/data/Books 0755 ${primaryUser} users -"
    "d /media/data/Films 0755 ${primaryUser} users -"
    "z /media/data/Films 0755 ${primaryUser} users -"
    "d /media/data/Music 0755 ${primaryUser} users -"
    "z /media/data/Music 0755 ${primaryUser} users -"
    "d /media/data/Serials 0755 ${primaryUser} users -"
    "z /media/data/Serials 0755 ${primaryUser} users -"
    "d /media/data/Unsorted 0775 torrents users -"
    "z /media/data/Unsorted 0775 torrents users -"
  ];

  # Torrents user for file ownership (UID 1001 to match NFS anonuid)
  users.users.torrents = {
    isSystemUser = true;
    uid = 1001;
    group = "torrents";
    home = "/media/data/Unsorted";
    description = "Torrent service user";
  };
  users.groups.torrents.gid = 1001;
}
