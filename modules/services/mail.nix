{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;
  primaryEmail = config.ahiru.primaryUser.email;
in
{
  # ============================================================
  # Mail - Outbound email via Migadu SMTP
  # ============================================================
  # Credentials stored in /etc/msmtp-secrets (copy secrets/mail.yaml to Pi)

  # Generate msmtprc at activation from secrets file
  system.activationScripts.msmtp-config = {
    text = ''
      SECRETS="/etc/msmtp-secrets"
      if [ -f "$SECRETS" ]; then
        MSMTP_USER=$(${pkgs.yq}/bin/yq -r '.msmtp_user' "$SECRETS")
        MSMTP_PASS=$(${pkgs.yq}/bin/yq -r '.msmtp_password' "$SECRETS")

        cat > /etc/msmtprc << EOF
defaults
auth           on
tls            on
tls_starttls   off
logfile        /var/log/msmtp.log
aliases        /etc/aliases

account        default
host           smtp.migadu.com
port           465
user           $MSMTP_USER
from           $MSMTP_USER
password       $MSMTP_PASS
EOF

        chmod 644 /etc/msmtprc
        echo "msmtp configured for $MSMTP_USER"
      else
        echo "Warning: $SECRETS not found, msmtp not configured"
      fi
    '';
  };

  # Symlink sendmail to msmtp
  environment.systemPackages = [ pkgs.msmtp pkgs.mailutils ];

  systemd.tmpfiles.rules = [
    "L /usr/sbin/sendmail - - - - ${pkgs.msmtp}/bin/msmtp"
    "L /usr/bin/sendmail - - - - ${pkgs.msmtp}/bin/msmtp"
    "f /var/log/msmtp.log 0666 root root -"
  ];

  # Mail aliases - where to send root/system mail
  environment.etc."aliases" = {
    text = ''
      root: ${primaryEmail}
      ${primaryUser}: ${primaryEmail}
    '';
    mode = "0644";
  };
}
