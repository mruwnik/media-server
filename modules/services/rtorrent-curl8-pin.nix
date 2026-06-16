# ============================================================================
#  ⚠  TEMPORARY PIN — rtorrent / libtorrent-rakshasa  ⚠   REMOVE WHEN FIXED
# ============================================================================
# Symptom: rtorrent/libtorrent-rakshasa 0.16.5 built against libcurl >= 8.20
# busy-loops in libtorrent's epoll event loop — ANY SCGI/XMLRPC request pins a
# thread at 100% CPU and never replies, and no trackers are announced (0 peers),
# so Flood can't talk to rtorrent at all. curl is only the trigger; the bug is
# libtorrent's CurlSocket / poll_epoll handling of curl 8.x's internal eventfd.
#   rakshasa/libtorrent#722  (curl-8.x eventfd never drained)       fix: PR #721
#   rakshasa/libtorrent#756  (rpc callback forces epoll timeout=0)  fix: PR #775
# nixpkgs bumped curl 8.19.0 -> 8.20.0 (rev e820eb4, 2026-06-08) and shipped no
# libtorrent fix, so the rebuilt 0.16.5 regressed. Diagnosed 2026-06-17.
#
# WORKAROUND: pin ONLY rtorrent + libtorrent-rakshasa to the last pre-curl-8.20
# nixpkgs (rev 0c88e1f2, 2026-05-05, curl 8.19.0 — the known-good gen-75 build).
# Everything else stays on current nixpkgs, so security updates are unaffected.
#
# TO REMOVE (the warnings below nag on EVERY rebuild so this isn't forgotten):
#   1. delete this file and its import in hosts/ahiru/default.nix
#   2. delete the `nixpkgs-rtorrent-pin` input in flake.nix, then `nix flake lock`
#   3. rebuild; verify torrents via Flood's connection-test (should be instant,
#      and rtorrent should reach peers) — see tests/checks/torrent.sh
# When nixpkgs' libtorrent-rakshasa moves past the pinned version, the extra
# warning fires: that build likely carries PR #721/#775 — drop the pin and test.
# ============================================================================
{ inputs, lib, pkgs, ... }:
let
  system = pkgs.stdenv.hostPlatform.system;
  pinned = import inputs.nixpkgs-rtorrent-pin { inherit system; config = { }; };
  pinnedVer = pinned.libtorrent-rakshasa.version;
  # Read the CURRENT nixpkgs' version directly from the input (our overlay below
  # has already replaced pkgs.libtorrent-rakshasa, so we can't read it from pkgs).
  upstreamVer = (import inputs.nixpkgs { inherit system; config = { }; }).libtorrent-rakshasa.version;
in
{
  nixpkgs.overlays = [
    (final: prev: {
      rtorrent = pinned.rtorrent;
      libtorrent-rakshasa = pinned.libtorrent-rakshasa;
    })
  ];

  # Printed by every `nixos-rebuild` — keeps the pin visible so it gets removed.
  warnings =
    [ ("ahiru: rtorrent + libtorrent-rakshasa are PINNED to pre-curl-8.20 nixpkgs"
       + " (${pinnedVer}) to dodge the libtorrent epoll busy-loop"
       + " (rakshasa/libtorrent#722,#756). Remove"
       + " modules/services/rtorrent-curl8-pin.nix once upstream ships the fix.") ]
    ++ lib.optional (upstreamVer != pinnedVer)
      ("ahiru: *** nixpkgs now has libtorrent-rakshasa ${upstreamVer} (pin holds"
       + " it at ${pinnedVer}). CHECK whether it carries the curl-8.x epoll fix"
       + " (PR #721/#775) and REMOVE the rtorrent pin if so. ***");
}
