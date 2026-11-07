{ ... }:

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
}
