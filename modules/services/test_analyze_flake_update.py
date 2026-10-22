import pytest

from analyze_flake_update import apply_hint, classify

CLOSURE = {
    "linux-rpi-6.6.51",
    "linux-rpi-6.6.51-modules",
    "dbus-1",
    "dbus-1.14.10",
    "nginx.conf",
    "openssl-3.0.14",
    "curl-8.20.0",
}


def bucket(rebuild):
    new_versions, hash_only = classify([rebuild], CLOSURE)
    return {"new": [r for _, _, r in new_versions], "hash": [r for _, _, r in hash_only]}


@pytest.mark.parametrize(
    "rebuild, expected",
    [
        ("openssl-3.0.15", {"new": ["openssl-3.0.15"], "hash": []}),
        ("curl-8.20.0", {"new": [], "hash": ["curl-8.20.0"]}),
        # Build-time intermediate of an unchanged kernel: same version.
        ("linux-rpi-6.6.51-modules-shrunk", {"new": [], "hash": ["linux-rpi-6.6.51-modules-shrunk"]}),
        ("linux-rpi-6.6.60-modules-shrunk", {"new": ["linux-rpi-6.6.60-modules-shrunk"], "hash": []}),
        # Generated config, not packages.
        ("dbus-1", {"new": [], "hash": []}),
        ("nginx.conf", {"new": [], "hash": []}),
        ("dbus-1.14.11", {"new": ["dbus-1.14.11"], "hash": []}),
        ("not-in-closure-1.0", {"new": [], "hash": []}),
    ],
)
def test_classify(rebuild, expected):
    assert bucket(rebuild) == expected


@pytest.mark.parametrize(
    "inputs, command",
    [
        (["nixpkgs"], "nix flake update nixpkgs"),
        (["nixpkgs", "sops-nix"], "nix flake update nixpkgs sops-nix"),
    ],
)
def test_apply_hint_bumps_only_changed_inputs_and_pushes(inputs, command):
    hint = "\n".join(apply_hint(inputs, []))
    assert command in hint
    assert "git push" in hint


@pytest.mark.parametrize(
    "rebuilds, warns",
    [
        (["linux-rpi-6.6.51-modules-shrunk"], True),
        (["openssl-3.0.15"], False),
    ],
)
def test_apply_hint_warns_about_kernel_rebuild(rebuilds, warns):
    assert ("kernel" in "\n".join(apply_hint(["nixpkgs"], rebuilds)).lower()) is warns
