#!/usr/bin/env bash
# Deploy secrets to the Pi
# Usage: ./deploy-secrets.sh [user@host]

set -euo pipefail

HOST="${1:-dan@ahiru.pl}"
SECRETS_DIR="$(dirname "$0")/secrets"

echo "Deploying secrets to $HOST..."

# Check secrets directory exists
if [ ! -d "$SECRETS_DIR" ]; then
  echo "Error: secrets/ directory not found"
  exit 1
fi

# Build the commands to run on the remote host
REMOTE_COMMANDS=""

# Mail config (msmtp)
if [ -f "$SECRETS_DIR/mail.yaml" ]; then
  echo "  → mail.yaml → /etc/msmtp-secrets"
  scp -q "$SECRETS_DIR/mail.yaml" "$HOST:/tmp/mail.yaml"
  REMOTE_COMMANDS+="sudo mv /tmp/mail.yaml /etc/msmtp-secrets && sudo chmod 600 /etc/msmtp-secrets; "
fi

# Filen backup config
if [ -f "$SECRETS_DIR/filen.yaml" ]; then
  echo "  → filen.yaml → /etc/filen-secrets"
  scp -q "$SECRETS_DIR/filen.yaml" "$HOST:/tmp/filen.yaml"
  REMOTE_COMMANDS+="sudo mv /tmp/filen.yaml /etc/filen-secrets && sudo chmod 600 /etc/filen-secrets; "
fi

# Update notifications config
if [ -f "$SECRETS_DIR/updates.yaml" ]; then
  echo "  → updates.yaml → /etc/update-notify-config"
  scp -q "$SECRETS_DIR/updates.yaml" "$HOST:/tmp/updates.yaml"
  REMOTE_COMMANDS+="sudo mv /tmp/updates.yaml /etc/update-notify-config && sudo chmod 644 /etc/update-notify-config; "
fi

# Monitoring config
if [ -f "$SECRETS_DIR/monitoring.yaml" ]; then
  echo "  → monitoring.yaml → /etc/monitoring-config"
  scp -q "$SECRETS_DIR/monitoring.yaml" "$HOST:/tmp/monitoring.yaml"
  REMOTE_COMMANDS+="sudo mv /tmp/monitoring.yaml /etc/monitoring-config && sudo chmod 644 /etc/monitoring-config; "
fi

# HTTP Basic Auth users - generate htpasswd locally and copy
if [ -f "$SECRETS_DIR/htpasswd.yaml" ]; then
  echo "  → htpasswd.yaml → /etc/htpasswd-secrets + /etc/shared-htpasswd"

  # Generate htpasswd file locally
  rm -f /tmp/shared-htpasswd
  current_user=""
  while IFS= read -r line; do
    if [[ "$line" =~ username:[[:space:]]*\"?([^\"]*)\"? ]]; then
      current_user="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ password:[[:space:]]*\"?([^\"]*)\"? ]] && [ -n "$current_user" ]; then
      pass="${BASH_REMATCH[1]}"
      if [[ "$pass" == \$* ]]; then
        echo "$current_user:$pass" >> /tmp/shared-htpasswd
      else
        salt=$(openssl rand -base64 6 | tr -dc "a-zA-Z0-9" | head -c 8)
        hash=$(openssl passwd -apr1 -salt "$salt" "$pass")
        echo "$current_user:$hash" >> /tmp/shared-htpasswd
      fi
      current_user=""
    fi
  done < "$SECRETS_DIR/htpasswd.yaml"

  echo "    Generated htpasswd with $(wc -l < /tmp/shared-htpasswd | tr -d ' ') users"

  # Copy both files
  scp -q "$SECRETS_DIR/htpasswd.yaml" "$HOST:/tmp/htpasswd.yaml"
  scp -q /tmp/shared-htpasswd "$HOST:/tmp/shared-htpasswd"
  rm -f /tmp/shared-htpasswd

  REMOTE_COMMANDS+='
    sudo mv /tmp/htpasswd.yaml /etc/htpasswd-secrets && sudo chmod 600 /etc/htpasswd-secrets
    sudo mv /tmp/shared-htpasswd /etc/shared-htpasswd
    sudo chown root:htpasswd-readers /etc/shared-htpasswd
    sudo chmod 640 /etc/shared-htpasswd
  '
fi

# Test services script - bake in credentials from htpasswd.yaml
SCRIPT_DIR="$(dirname "$0")"
if [ -f "$SCRIPT_DIR/test-services.sh" ] && [ -f "$SECRETS_DIR/htpasswd.yaml" ]; then
  echo "  → test-services.sh → /root/test-services.sh (with baked-in credentials)"

  # Get the last user from htpasswd.yaml
  TEST_USER=$(grep -E '^\s*-?\s*username:' "$SECRETS_DIR/htpasswd.yaml" | tail -1 | sed 's/.*username:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/')
  TEST_PASS=$(grep -E '^\s*password:' "$SECRETS_DIR/htpasswd.yaml" | tail -1 | sed 's/.*password:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/')

  # Create modified script with baked-in defaults
  sed -e "s|^USER=\"\$1\"$|USER=\"\${1:-$TEST_USER}\"|" \
      -e "s|^PASS=\"\$2\"$|PASS=\"\${2:-$TEST_PASS}\"|" \
      -e '/if \[\[ \$# -lt 2 \]\]/,/^fi$/d' \
      "$SCRIPT_DIR/test-services.sh" > /tmp/test-services-modified.sh

  scp -q /tmp/test-services-modified.sh "$HOST:/tmp/test-services.sh"
  rm -f /tmp/test-services-modified.sh
  REMOTE_COMMANDS+="sudo mv /tmp/test-services.sh /root/test-services.sh && sudo chmod 700 /root/test-services.sh; "
fi

# Execute remote commands
if [ -n "$REMOTE_COMMANDS" ]; then
  ssh "$HOST" "$REMOTE_COMMANDS"
fi

echo "Done!"
