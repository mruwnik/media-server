{ config, pkgs, ... }:

let
  py = pkgs.python3Packages;

  # Not in nixpkgs. Upstream pins ancient jsonpickle/cachetools; it runs fine on current ones.
  drain3 = py.buildPythonPackage rec {
    pname = "drain3";
    version = "0.9.11";
    format = "setuptools";
    src = pkgs.fetchPypi {
      inherit pname version;
      hash = "sha256-mrSxQH+tdPVlVK43HvAZw8eYWGFjH0urRqDpJYUSX3U=";
    };
    propagatedBuildInputs = [ py.jsonpickle py.cachetools ];
    pythonRelaxDeps = true;
    doCheck = false;
  };

  log-review = pkgs.writers.writePython3Bin "log-review" {
    libraries = [ drain3 ];
    flakeIgnore = [ "E501" "W503" "E203" ];
  } (builtins.readFile ./log_review.py);
in
{
  environment.systemPackages = [ log-review ];

  # Reports + drain state; tmpfiles ages out old reports.
  systemd.tmpfiles.rules = [ "d /var/lib/log-review 0750 root root 60d" ];

  systemd.services.log-review = {
    description = "Daily templated log digest (journal, nginx, DNS)";
    path = [ pkgs.systemd pkgs.getent pkgs.gawk pkgs.iproute2 config.networking.firewall.package ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Nice = 15;
      IOSchedulingClass = "idle";
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/log-review" ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
    script = ''
      export WAN_IP=$(getent ahosts ahiru.pl | awk 'NR==1 {print $1}')
      exec ${log-review}/bin/log-review --zero-counters
    '';
  };

  systemd.timers.log-review = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00:20:00";
      Persistent = true;
    };
  };
}
