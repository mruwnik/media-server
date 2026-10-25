# nixos-26.05 ships rtorrent/libtorrent 0.16.11; upstream has since fixed its
# UdpRouter, tracker stalls and udns heap overflows (Sept 2026). The old
# curl-8.20 busy-loop pin is moot since curl 8.21. 0.16.26 renamed the log
# levels the module's rc template uses, so stay on 0.16.25 until nixpkgs
# updates both package and module; drop this file then.
{ inputs, lib, pkgs, ... }:
let
  version = "0.16.25";
  upstream = (import inputs.nixpkgs { inherit (pkgs.stdenv.hostPlatform) system; }).libtorrent-rakshasa.version;
  fromTag = repo: hash: _: {
    inherit version;
    src = pkgs.fetchFromGitHub {
      owner = "rakshasa";
      inherit repo hash;
      tag = "v${version}";
    };
  };
in
{
  nixpkgs.overlays = [
    (final: prev: {
      libtorrent-rakshasa = prev.libtorrent-rakshasa.overrideAttrs
        (fromTag "libtorrent" "sha256-WxhAu2BXxlqPidoItMXnKyw5uTUk9ogmUBWohIdvQSo=");
      # The 26.05 module's rc template uses commands 0.16.25 only accepts under
      # -D (network.port_range.set, network.http.max_open.set, ...); default it on.
      rtorrent = (prev.rtorrent.overrideAttrs
        (fromTag "rtorrent" "sha256-uZ1Y3fKOv0KaUBRjuanEkkB88E+U8/cOBEcFrLjiHC0=")).overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace src/command_dynamic.cc \
              --replace-fail '("method.use_deprecated", false)' '("method.use_deprecated", true)'
          '';
        });
    })
  ];

  # encoding.add (in that same template) was removed outright, -D or not.
  services.rtorrent.configText = lib.mkOrder 400 ''
    method.insert = encoding.add, simple, ""
  '';

  warnings = lib.optional (lib.versionAtLeast upstream version)
    "ahiru: nixpkgs now has libtorrent-rakshasa ${upstream}; delete modules/services/rtorrent-latest.nix";
}
