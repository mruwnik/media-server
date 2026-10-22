import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

SECURITY_PATTERN = re.compile(
    r"^(linux|kernel|openssl|openssh|curl|glibc|gcc|nginx|samba|dbus|sudo|"
    r"systemd|nss-cacert|wireguard|gnutls|expat|libxml|libxslt|sqlite|pcre|"
    r"bash|coreutils|util-linux|shadow|pam|polkit|cryptsetup|libgcrypt|"
    r"nettle|libtasn1|libssh|krb5|libcap|zlib|tar|xz|gzip|ncurses)(\b|2|3)"
)
HASH_PREFIX = re.compile(r"^[a-z0-9]{32}-")
VERSION_SPLIT = re.compile(r"^(.+?)-([0-9]+(?:\.[0-9]+)*[\w.\-]*)$")
BASE_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)*")
CVE_RE = re.compile(r"CVE-\d{4}-\d+")
BUMP_RE = re.compile(r"^([\w.\-]+(?:Packages\.[\w-]+)?)\s*:\s*([\d.\w\-]+)\s*->\s*([\d.\w\-]+)")
# Infrastructure / generated derivations that always rebuild — not actual
# package updates the user can act on.
NOISE_PATTERN = re.compile(
    r"^(nixos-system|system-units|user-units|system-path|etc|etc-|unit-|"
    r"X-Restart-Triggers|nixos-help|nixos-manual|nixos-configuration|"
    r"closure-info|initrd-|boot\.json|shutdown-ramfs|migrate-rpi-firmware|"
    r"raspberry-pi-firmware|nixos-version|os-release|issue|dbus-1$|.*\.(conf|json)$)"
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


def base_version(ver):
    m = BASE_VERSION.match(ver)
    return m.group(0) if m else ver


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


def dry_build(work_dir):
    result = subprocess.run(
        ["nixos-rebuild", "dry-build", "--flake", f"path:{work_dir}#ahiru"],
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


def classify(rebuilds, closure):
    """Split dry-build derivations into (new_versions, hash_only)."""
    closure_versions = {}
    for n in closure:
        pkg, ver = split_version(n)
        closure_versions.setdefault(pkg, set()).add(base_version(ver))
    new_versions = []
    hash_only = []
    for r in rebuilds:
        if NOISE_PATTERN.match(r):
            continue
        pkg, ver = split_version(r)
        # Build intermediates (e.g. linux-rpi-X-modules-shrunk) never land in
        # the closure under their own name, so compare versions, not names.
        if base_version(ver) in closure_versions.get(pkg, ()):
            hash_only.append((pkg, ver, r))
        elif pkg in closure_versions:
            new_versions.append((pkg, ver, r))
    return new_versions, hash_only


def apply_hint(inputs, rebuilds):
    lines = [
        "On your machine (the Pi deploys origin/master daily):",
        f"  nix flake update {' '.join(sorted(inputs))}",
        "  git commit -m 'Bump flake inputs' flake.lock && git push",
    ]
    if any(r.startswith("linux-rpi") for r in rebuilds):
        lines.append("Warning: includes a kernel rebuild — ~8h on the Pi (no binary cache).")
    return lines


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
    if len(sys.argv) != 4:
        sys.stderr.write("usage: analyze-flake-update OLD_LOCK NEW_LOCK WORK_DIR\n")
        sys.exit(2)
    old_lock, new_lock, work_dir = sys.argv[1:4]
    old = load(old_lock)
    new = load(new_lock)
    changes = input_diff(old, new)

    if not changes:
        print("No upstream updates")
        print()
        print("Daily flake-update check on ahiru.pl found no new revisions on any input.")
        print("(Sent as a heartbeat — service is alive.)")
        return

    drybuild_rc, drybuild_out = dry_build(work_dir)
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
    new_versions, hash_only = classify(rebuilds, current_closure())

    cves_by_pkg = {}
    nixpkgs_change = changes.get("nixpkgs")
    if nixpkgs_change and nixpkgs_change[0] and nixpkgs_change[1]:
        cves_by_pkg = fetch_cves(nixpkgs_change[0], nixpkgs_change[1])

    sec_versions = [v for v in new_versions if SECURITY_PATTERN.match(v[0])]
    sec_hash_only = [h for h in hash_only if SECURITY_PATTERN.match(h[0])]
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
    print("\n".join(apply_hint(changes, rebuilds)))


if __name__ == "__main__":
    main()
