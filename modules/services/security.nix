{ config, lib, pkgs, ... }:

let
  # Service users that never initiate off-box connections; any NEW outbound
  # flow from them is logged and alerted on by tests/checks/security.sh.
  # mcp is logged too (it legitimately calls a few APIs) for the daily review.
  # Static users only: a name iptables can't resolve aborts the firewall.
  watchedUsers = [ "nginx" "mpd" "radicale" "mcp" ];
  # Byte counters for log-review's Traffic section; position + 1 is the user's connmark.
  accountedUsers = [ "torrents" ] ++ watchedUsers;
  # Services whose every exec is alerted on by tests/checks/security.sh.
  execWatchedUsers = [ "torrents" "nginx" "mpd" "radicale" ];
  forEachUser = users: f: lib.concatLines (lib.imap1 f users);
in
{
  networking.firewall.extraCommands = ''
    ip46tables -D OUTPUT -j out-watch 2>/dev/null || true
    ip46tables -D OUTPUT -j acct-out 2>/dev/null || true
    ip46tables -D INPUT -j acct-in 2>/dev/null || true
    for chain in out-watch out-torrents out-block acct-in acct-out; do
      ip46tables -F $chain 2>/dev/null || ip46tables -N $chain
    done

    # rtorrent (and Flood, same uid) only needs public peers and trackers; the
    # LAN and remote-admin/mail ports are pivot targets. Loopback (local DNS) is
    # exempt via out-watch's lo rule, and the router is resolv.conf's fallback.
    ip46tables -A out-block -m limit --limit 6/min --limit-burst 20 -j LOG --log-prefix "out-block rtorrent: "
    ip46tables -A out-block -j REJECT
    iptables -A out-torrents -d 192.168.0.1 -p udp --dport 53 -j RETURN
    iptables -A out-torrents -d 192.168.0.1 -p tcp --dport 53 -j RETURN
    iptables -A out-torrents -d 192.168.0.0/16 -j out-block
    iptables -A out-torrents -d 10.0.0.0/8 -j out-block
    ip6tables -A out-torrents -d fc00::/7 -j out-block
    ip6tables -A out-torrents -d fe80::/10 -j out-block
    ip46tables -A out-torrents -p tcp -m multiport --dports 22,23,25,445,465,587,2222,3389 -j out-block

    ip46tables -A out-watch -o lo -j RETURN
    ip46tables -A out-watch -m owner --uid-owner torrents -m conntrack --ctstate NEW -j out-torrents
    ${lib.concatMapStrings (u: ''
      ip46tables -A out-watch -m owner --uid-owner ${u} -m conntrack --ctstate NEW \
        -m limit --limit 6/min --limit-burst 20 -j LOG --log-prefix "out-watch ${u}: "
    '') watchedUsers}
    ip46tables -A OUTPUT -j out-watch

    # Outbound bytes by socket owner; the connmark carries the owner over to the
    # inbound half of the same flows, where the owner match can't see.
    ip46tables -A acct-out -o lo -j RETURN
    ${forEachUser accountedUsers (i: u: ''
      ip46tables -A acct-out -m owner --uid-owner ${u} -m comment --comment "out ${u}" -j CONNMARK --set-xmark ${toString i}/0xff
    '')}
    ip46tables -A acct-in -i lo -j RETURN
    # A peer's SYN arrives before rtorrent's socket has marked the flow.
    ip46tables -A acct-in -p tcp --dport ${toString config.services.rtorrent.port} -m conntrack --ctstate NEW -j CONNMARK --set-xmark 1/0xff
    ${forEachUser accountedUsers (i: u: ''
      ip46tables -A acct-in -m connmark --mark ${toString i}/0xff -m comment --comment "in ${u}" -j RETURN
    '')}
    # A reload resets the counters; log-review reads this to flag a partial day.
    ip46tables -A acct-in -m comment --comment "since $(date +%s)"
    ip46tables -I INPUT 1 -j acct-in
    ip46tables -A OUTPUT -j acct-out
  '';

  networking.firewall.extraStopCommands = ''
    ip46tables -D OUTPUT -j out-watch 2>/dev/null || true
    ip46tables -D OUTPUT -j acct-out 2>/dev/null || true
    ip46tables -D INPUT -j acct-in 2>/dev/null || true
  '';

  # Tripwire: these services never exec anything, bar the rtorrent/Flood
  # helpers. Coreutils is one multicall binary here (rtorrent's mkdir/mv/chown/
  # chmod, Flood's df every 10s), so it is the one exclusion; rtorrent's
  # start-up `sh -c` calls are filtered by argv in tests/checks/security.sh.
  security.auditd.enable = true;
  security.audit = {
    enable = true;
    rules = [
      "-a never,exit -F arch=b64 -S execve -F uid=torrents -F exe=${pkgs.coreutils}/bin/coreutils"
    ] ++ map (u: "-a always,exit -F arch=b64 -S execve,execveat -F success=1 -F uid=${u} -k svc-exec") execWatchedUsers;
  };

  # Bans IPs that brute-force sshd or probe nginx, and pulls the community
  # blocklist in exchange for reporting our own bans (IP + scenario only:
  # console context sharing is off and the engine isn't enrolled).
  services.crowdsec = {
    enable = true;
    autoUpdateService = true;
    hub.collections = [ "crowdsecurity/linux" "crowdsecurity/sshd" "crowdsecurity/nginx" ];
    localConfig = {
      acquisitions = [
        { source = "journalctl"; journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ]; labels.type = "syslog"; }
        { source = "file"; filenames = [ "/var/log/nginx/access.log" "/var/log/nginx/error.log" ]; labels.type = "nginx"; }
      ];
      # LAN is already covered by the hub's crowdsecurity/whitelists.
      parsers.s02Enrich = [{
        name = "ahiru/whitelists";
        description = "Own WAN IP (LAN clients hairpinning via ahiru.pl) and the Claude.ai MCP connector";
        whitelist = {
          reason = "own traffic";
          ip = [ "194.181.243.144" ];
          cidr = [ "160.79.104.0/21" ];
        };
      }];
      profiles = [{
        name = "default_ip_remediation";
        filters = [ "Alert.Remediation == true && Alert.GetScope() == 'Ip'" ];
        decisions = [{ type = "ban"; duration = "4h"; }];
        on_success = "break";
      }];
    };
    settings = {
      # 8080 is myMPD.
      general.api.server = { enable = true; listen_uri = "127.0.0.1:8095"; };
      lapi.credentialsFile = "/var/lib/crowdsec/state/local_api_credentials.yaml";
      capi.credentialsFile = "/var/lib/crowdsec/state/online_api_credentials.yaml";
    };
  };

  systemd.services.crowdsec.serviceConfig = {
    # nixpkgs#509038: PrivateUsers drops the supplementary groups, so journal and
    # nginx log acquisition silently read nothing.
    PrivateUsers = lib.mkForce false;
    # Every start runs `cscli hub update`, which fails if blocky isn't up yet.
    Restart = "on-failure";
  };
  # go-re2 runs on wazero's interpreter here: compiling the grok patterns takes
  # >15 min of CPU instead of ~5s with Go's regexp.
  systemd.services.crowdsec.environment.CROWDSEC_FEATURE_RE2_DISABLE_GROK_SUPPORT = "true";
  users.users.crowdsec.extraGroups = [ "nginx" ];
  # The module's setup runs `cscli machines add` before `capi register`, and the
  # former refuses to start without the CAPI credentials file.
  systemd.tmpfiles.rules = [
    "f /var/lib/crowdsec/state/online_api_credentials.yaml 0600 crowdsec crowdsec -"
  ];
  # The bouncer-register script calls the unwrapped cscli, which only looks here.
  environment.etc."crowdsec/config.yaml".source =
    (pkgs.formats.yaml { }).generate "crowdsec.yaml" config.services.crowdsec.settings.general;

  services.crowdsec-firewall-bouncer.enable = true;
  # With DynamicUser its StateDirectory=crowdsec moves /var/lib/crowdsec into
  # /var/lib/private, where crowdsec.service (no StateDirectory) can't reach it.
  systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.DynamicUser = lib.mkForce false;
  # Upstream only Requires= it, so the bouncer races the API key into existence.
  systemd.services.crowdsec-firewall-bouncer.after = [ "crowdsec-firewall-bouncer-register.service" ];
}
