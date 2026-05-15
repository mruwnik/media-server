{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;

  # Closure-aware analyzer: given the old and new flake.lock and a working
  # directory holding the updated flake, emits an email body to stdout.
  # First line is the subject (without the [ahiru] prefix).
  analyzeFlakeUpdate = pkgs.writers.writePython3Bin "analyze-flake-update" { } ''
    import json
    import os
    import re
    import subprocess
    import sys
    import urllib.error
    import urllib.request

    if len(sys.argv) != 4:
        sys.stderr.write("usage: analyze-flake-update OLD_LOCK NEW_LOCK WORK_DIR\n")
        sys.exit(2)

    OLD_LOCK, NEW_LOCK, WORK_DIR = sys.argv[1:4]

    SECURITY_PATTERN = re.compile(
        r"^(linux|kernel|openssl|openssh|curl|glibc|gcc|nginx|samba|dbus|sudo|"
        r"systemd|nss-cacert|wireguard|gnutls|expat|libxml|libxslt|sqlite|pcre|"
        r"bash|coreutils|util-linux|shadow|pam|polkit|cryptsetup|libgcrypt|"
        r"nettle|libtasn1|libssh|krb5|libcap|zlib|tar|xz|gzip|ncurses)(\b|2|3)"
    )
    HASH_PREFIX = re.compile(r"^[a-z0-9]{32}-")
    VERSION_SPLIT = re.compile(r"^(.+?)-([0-9]+(?:\.[0-9]+)*[\w.\-]*)$")
    CVE_RE = re.compile(r"CVE-\d{4}-\d+")
    BUMP_RE = re.compile(r"^([\w.\-]+(?:Packages\.[\w-]+)?)\s*:\s*([\d.\w\-]+)\s*->\s*([\d.\w\-]+)")
    # Infrastructure / generated derivations that always rebuild — not actual
    # package updates the user can act on.
    NOISE_PATTERN = re.compile(
        r"^(nixos-system|system-units|user-units|system-path|etc|etc-|unit-|"
        r"X-Restart-Triggers|nixos-help|nixos-manual|nixos-configuration|"
        r"closure-info|initrd-|boot\.json|shutdown-ramfs|migrate-rpi-firmware|"
        r"raspberry-pi-firmware|nixos-version|os-release|issue)"
    )


    def load(p):
        with open(p) as f:
            return json.load(f)


    def store_name(path):
        base = os.path.basename(path)
        base = HASH_PREFIX.sub("", base)
        if base.endswith(".drv"):
            base = base[:-4]
        return base


    def split_version(name):
        m = VERSION_SPLIT.match(name)
        if m:
            return m.group(1), m.group(2)
        return name, ""


    def input_diff(old, new):
        changes = {}
        for name, node in new.get("nodes", {}).items():
            if name == "root":
                continue
            old_node = old.get("nodes", {}).get(name)
            new_rev = node.get("locked", {}).get("rev")
            old_rev = old_node.get("locked", {}).get("rev") if old_node else None
            if old_rev != new_rev:
                changes[name] = (old_rev, new_rev)
        for name in old.get("nodes", {}):
            if name == "root" or name in new.get("nodes", {}):
                continue
            changes[name] = (old["nodes"][name].get("locked", {}).get("rev"), None)
        return changes


    def dry_build():
        result = subprocess.run(
            ["nixos-rebuild", "dry-build", "--flake", f"path:{WORK_DIR}#ahiru"],
            capture_output=True,
            text=True,
        )
        return result.returncode, (result.stderr or "") + (result.stdout or "")


    def parse_rebuilds(output):
        rebuilds = []
        in_section = False
        for line in output.splitlines():
            if re.match(r"these \d+ derivations? will be built:", line):
                in_section = True
                continue
            if in_section:
                stripped = line.strip()
                if stripped.startswith("/nix/store/"):
                    rebuilds.append(store_name(stripped))
                else:
                    in_section = False
        return rebuilds


    def current_closure():
        result = subprocess.run(
            ["nix-store", "-qR", "/run/current-system"],
            capture_output=True,
            text=True,
            check=True,
        )
        names = set()
        for line in result.stdout.splitlines():
            names.add(store_name(line))
        return names


    def fetch_cves(old_rev, new_rev):
        # The compare endpoint caps at 250 commits per page; paginate.
        by_pkg = {}
        for page in range(1, 21):
            url = (
                f"https://api.github.com/repos/NixOS/nixpkgs/compare/"
                f"{old_rev}...{new_rev}?per_page=100&page={page}"
            )
            req = urllib.request.Request(url, headers={"User-Agent": "ahiru-update-check"})
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    data = json.loads(resp.read())
            except (urllib.error.URLError, json.JSONDecodeError) as exc:
                sys.stderr.write(f"CVE fetch page {page} failed: {exc}\n")
                break
            commits = data.get("commits", [])
            if not commits:
                break
            for commit in commits:
                msg = commit.get("commit", {}).get("message", "")
                first = msg.split("\n", 1)[0].split("(")[0].strip()
                m = BUMP_RE.match(first)
                if not m:
                    continue
                pkg_full = m.group(1)
                pkg = pkg_full.split(".")[-1].lower()
                cves = sorted(set(CVE_RE.findall(msg)))
                if cves:
                    by_pkg.setdefault(pkg, set()).update(cves)
            if len(commits) < 100:
                break
        return {k: sorted(v) for k, v in by_pkg.items()}


    def main():
        old = load(OLD_LOCK)
        new = load(NEW_LOCK)
        changes = input_diff(old, new)

        if not changes:
            print("No upstream updates")
            print()
            print(f"Daily flake-update check on ahiru.pl found no new revisions on any input.")
            print("(Sent as a heartbeat — service is alive.)")
            return

        drybuild_rc, drybuild_out = dry_build()
        if drybuild_rc != 0:
            print("Flake bumped but dry-build FAILED")
            print()
            print("=== Flake input changes ===")
            for inp, (old_rev, new_rev) in sorted(changes.items()):
                o = (old_rev or "(new)")[:10]
                n = (new_rev or "(removed)")[:10]
                print(f"  {inp}: {o} -> {n}")
            print()
            print("=== Dry-build output (last 40 lines) ===")
            print("\n".join(drybuild_out.splitlines()[-40:]))
            return
        rebuilds = parse_rebuilds(drybuild_out)
        closure = current_closure()
        closure_pkgs = {split_version(n)[0] for n in closure}

        new_versions = []
        hash_only = []
        for r in rebuilds:
            if NOISE_PATTERN.match(r):
                continue
            pkg, ver = split_version(r)
            if r in closure:
                hash_only.append((pkg, ver, r))
            elif pkg in closure_pkgs:
                new_versions.append((pkg, ver, r))

        cves_by_pkg = {}
        nixpkgs_change = changes.get("nixpkgs")
        if nixpkgs_change and nixpkgs_change[0] and nixpkgs_change[1]:
            cves_by_pkg = fetch_cves(nixpkgs_change[0], nixpkgs_change[1])

        sec_versions = [v for v in new_versions if SECURITY_PATTERN.match(v[0])]
        sec_hash_only = [h for h in hash_only if SECURITY_PATTERN.match(h[0])]
        total_cves = sum(len(c) for c in cves_by_pkg.values())
        closure_cves = sum(
            len(cves_by_pkg.get(pkg, [])) for pkg, _, _ in new_versions
        )

        # Subject (first line)
        if not new_versions and not hash_only:
            subject = "Flake bump, no closure impact"
        elif sec_versions:
            subject = (
                f"Security-sensitive updates: {len(sec_versions)} pkg, "
                f"{closure_cves} CVEs in closure"
            )
        elif new_versions:
            subject = f"{len(new_versions)} closure package update(s) available"
        else:
            subject = f"{len(hash_only)} hash-only rebuilds, no version changes"

        print(subject)
        print()
        print("=== Flake input changes ===")
        for inp, (old_rev, new_rev) in sorted(changes.items()):
            o = (old_rev or "(new)")[:10]
            n = (new_rev or "(removed)")[:10]
            print(f"  {inp}: {o} -> {n}")

        if sec_versions:
            print()
            print("=== Security-sensitive package updates in closure ===")
            for pkg, ver, _ in sorted(sec_versions):
                cves = cves_by_pkg.get(pkg, [])
                tail = f"  [{', '.join(cves)}]" if cves else ""
                print(f"  {pkg} -> {ver}{tail}")

        other_versions = [v for v in new_versions if not SECURITY_PATTERN.match(v[0])]
        if other_versions:
            print()
            print("=== Other closure package updates ===")
            for pkg, ver, _ in sorted(other_versions)[:40]:
                cves = cves_by_pkg.get(pkg, [])
                tail = f"  [{', '.join(cves)}]" if cves else ""
                print(f"  {pkg} -> {ver}{tail}")
            if len(other_versions) > 40:
                print(f"  ... and {len(other_versions) - 40} more")

        if sec_hash_only:
            print()
            print("=== Hash-only rebuilds of security-sensitive packages ===")
            print("(same version, rebuilt against new stdenv — no source change)")
            for pkg, ver, _ in sorted(sec_hash_only):
                print(f"  {pkg}-{ver}")

        if not new_versions and hash_only:
            print()
            print(f"({len(hash_only)} hash-only rebuilds total — same versions, "
                  "would recompile only.)")

        print()
        print("=== To apply ===")
        print(f"  ssh {os.environ.get('PRIMARY_USER', 'dan')}@ahiru.pl")
        print("  cd ~/nixos && nix flake update")
        print("  sudo nixos-rebuild switch --flake .#ahiru")


    main()
  '';
in
{
  # ============================================================
  # Auto-Update Service - Pulls config changes and rebuilds
  # ============================================================
  # Configure recipient in /etc/update-notify-config:
  #   notify_email: "your@email.com"

  # Daily timer to check for updates
  systemd.timers.nixos-update-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";  # Spread load
    };
  };

  systemd.services.nixos-update-check = {
    description = "Auto-update NixOS from git and notify via email";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      git
      nix
      coreutils
      gnugrep
      diffutils
      msmtp
      nixos-rebuild
      gnutar
      analyzeFlakeUpdate
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };

    script = ''
      set -euo pipefail

      CONFIG="/etc/update-notify-config"
      NIXOS_DIR="/home/${primaryUser}/nixos"
      LOG_FILE="/tmp/nixos-rebuild-$$.log"
      export PRIMARY_USER="${primaryUser}"

      # Allow root to access user-owned git repo
      git config --global --add safe.directory "$NIXOS_DIR" 2>/dev/null || true

      # Load config
      if [ ! -f "$CONFIG" ]; then
        echo "Config not found: $CONFIG - skipping update check"
        exit 0
      fi

      NOTIFY_EMAIL=$(${pkgs.yq}/bin/yq -r '.notify_email // empty' "$CONFIG")
      if [ -z "$NOTIFY_EMAIL" ]; then
        echo "No notify_email configured - skipping"
        exit 0
      fi

      # Check if nixos repo exists
      if [ ! -d "$NIXOS_DIR/.git" ]; then
        echo "NixOS config not found at $NIXOS_DIR"
        exit 0
      fi

      cd "$NIXOS_DIR"

      # Fetch latest from remote
      export GIT_SSH_COMMAND="ssh -i /home/${primaryUser}/.ssh/id_ed25519 -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"
      git fetch origin 2>/dev/null || true

      # Get current and remote commits
      LOCAL=$(git rev-parse HEAD)

      # Detect remote branch
      if git show-ref --verify --quiet refs/remotes/origin/main; then
        REMOTE_BRANCH="origin/main"
      else
        REMOTE_BRANCH="origin/master"
      fi
      REMOTE=$(git rev-parse "$REMOTE_BRANCH")

      # Check for config repo updates
      CONFIG_UPDATED=""
      COMMIT_LOG=""
      if [ "$LOCAL" != "$REMOTE" ]; then
        COMMITS_BEHIND=$(git rev-list --count HEAD.."$REMOTE_BRANCH")
        COMMIT_LOG=$(git log --oneline HEAD.."$REMOTE_BRANCH" | head -10)

        echo "Found $COMMITS_BEHIND new commit(s) - pulling and rebuilding..."

        # Pull changes
        git pull --ff-only origin "$(echo $REMOTE_BRANCH | sed 's|origin/||')" 2>&1 | tee -a "$LOG_FILE"

        # Rebuild
        if nixos-rebuild switch --flake .#ahiru 2>&1 | tee -a "$LOG_FILE"; then
          echo "Rebuild successful"
          CONFIG_UPDATED="success"
        else
          CONFIG_UPDATED="failed"
          echo "Rebuild failed"
        fi
      fi

      # Send config-update email if applicable
      if [ -n "$CONFIG_UPDATED" ]; then
        {
          if [ "$CONFIG_UPDATED" = "success" ]; then
            echo "Subject: [ahiru] NixOS config updated successfully"
          else
            echo "Subject: [ahiru] NixOS config update FAILED"
          fi
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""

          if [ "$CONFIG_UPDATED" = "success" ]; then
            echo "NixOS config on ahiru.pl has been updated successfully."
          else
            echo "NixOS config update on ahiru.pl FAILED. Manual intervention required."
          fi
          echo ""
          echo "=== Applied Commits ==="
          echo "$COMMIT_LOG"
          echo ""
          echo "=== Rebuild Output (last 50 lines) ==="
          tail -50 "$LOG_FILE"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl auto-updater"
        } | msmtp -t
      fi

      # ============================================================
      # Daily flake-update heartbeat with closure-aware analysis
      # ============================================================
      # Always sends one email per run. Subject classifies impact so
      # quiet days can be filtered by a mail rule if desired.

      WORK=$(mktemp -d)
      trap 'rm -rf "$WORK" "$LOG_FILE" /tmp/flake.lock.before' EXIT

      # Materialize the flake into a working dir so we never mutate
      # the live one. git archive captures tracked state; we then
      # overlay the live flake.lock (which may be ahead of HEAD).
      git archive HEAD | tar -x -C "$WORK"
      cp flake.lock "$WORK/flake.lock"
      cp "$WORK/flake.lock" /tmp/flake.lock.before

      echo "Refreshing flake inputs in $WORK..."
      if (cd "$WORK" && nix flake update --refresh) 2>&1 | tee -a "$LOG_FILE"; then
        BODY=$(analyze-flake-update /tmp/flake.lock.before "$WORK/flake.lock" "$WORK" 2>&1 || echo "Analyzer failed; see service journal.")
        SUBJECT=$(printf '%s\n' "$BODY" | head -n1)
        REST=$(printf '%s\n' "$BODY" | tail -n +2)
        {
          echo "Subject: [ahiru] $SUBJECT"
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""
          echo "$REST"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl update checker (heartbeat: always sends)"
        } | msmtp -t
      else
        {
          echo "Subject: [ahiru] Update checker: flake refresh FAILED"
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""
          echo "nix flake update --refresh failed. Last 50 log lines:"
          echo ""
          tail -50 "$LOG_FILE"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl update checker"
        } | msmtp -t
      fi

      rm -f /tmp/flake.lock.before

      if [ "$CONFIG_UPDATED" = "failed" ]; then
        exit 1
      fi
    '';
  };
}
