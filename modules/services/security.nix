{ config, lib, pkgs, ... }:

let
  # Service users that never initiate off-box connections; any NEW outbound
  # flow from them is logged and alerted on by tests/checks/security.sh.
  # mcp is logged too (it legitimately calls a few APIs) for the daily review.
  # Static users only: a name iptables can't resolve aborts the firewall.
  watchedUsers = [ "nginx" "mpd" "radicale" "mcp" ];
in
{
  networking.firewall.extraCommands = ''
    ip46tables -D OUTPUT -j out-watch 2>/dev/null || true
    ip46tables -F out-watch 2>/dev/null || ip46tables -N out-watch
    ip46tables -A out-watch -o lo -j RETURN
    ${builtins.concatStringsSep "\n" (map (u: ''
      ip46tables -A out-watch -m owner --uid-owner ${u} -m conntrack --ctstate NEW \
        -m limit --limit 6/min --limit-burst 20 -j LOG --log-prefix "out-watch ${u}: "
    '') watchedUsers)}
    ip46tables -A OUTPUT -j out-watch
  '';

  networking.firewall.extraStopCommands = ''
    ip46tables -D OUTPUT -j out-watch 2>/dev/null || true
  '';

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
