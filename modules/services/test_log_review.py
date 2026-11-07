import pytest

from collections import Counter

from log_review import (
    Patterns, Siphon, client_bucket, fence, new_miner, parse_dns, parse_nginx,
    render_logins, render_nginx, render_traffic, triage,
)

WAN = "194.181.243.144"


@pytest.mark.parametrize(
    "ip, expected",
    [
        ("192.168.0.105", "lan"),
        ("127.0.0.1", "lan"),
        ("::1", "lan"),
        ("160.79.104.10", "anthropic"),
        ("160.79.111.255", "anthropic"),
        ("160.79.112.1", "public"),
        (WAN, "wan"),
        ("93.152.221.151", "public"),
        ("2a01:4f8::1", "public"),
        ("not-an-ip", "public"),
    ],
)
def test_client_bucket(ip, expected):
    assert client_bucket(ip, WAN) == expected


@pytest.mark.parametrize(
    "line, expected",
    [
        (
            '93.152.221.151 - - [03/Nov/2026:22:01:02 +0100] "POST /login?x=1 HTTP/1.1" 200 1234 "-" "curl/8"',
            {"ip": "93.152.221.151", "method": "POST", "path": "/login?x=1", "status": "200", "ua": "curl/8"},
        ),
        (
            '1.2.3.4 - dan [03/Nov/2026:22:01:02 +0100] "\\x16\\x03\\x01" 400 157 "-" "-"',
            {"ip": "1.2.3.4", "method": "-", "path": "\\x16\\x03\\x01", "status": "400", "ua": "-"},
        ),
        ("garbage", None),
    ],
)
def test_parse_nginx(line, expected):
    assert parse_nginx(line) == expected


@pytest.mark.parametrize(
    "line, expected",
    [
        (
            "2026-11-07 16:56:35\t192.168.0.198\t192.168.0.198\t3\tCACHED\tnyaa.tracker.wf.\tA (1.2.3.4)\tNOERROR\tCACHED\tA\tahiru",
            {"client": "192.168.0.198", "reason": "CACHED", "name": "nyaa.tracker.wf."},
        ),
        ("short\tline", None),
    ],
)
def test_parse_dns(line, expected):
    assert parse_dns(line) == expected


def mine(miner, lines):
    patterns = Patterns(miner)
    for line in lines:
        patterns.add(line)
    return {p.template: p for p in patterns.result()}


def test_patterns_flag_only_unseen_templates_as_new():
    miner = new_miner()
    mine(miner, [f"sshd: Accepted publickey for git from 18.196.115.{i} port 5{i}" for i in range(20)])

    today = mine(
        miner,
        [f"sshd: Accepted publickey for git from 18.196.115.{i} port 6{i}" for i in range(5)]
        + ["sshd: Accepted publickey for root from 6.6.6.6 port 1 via evil"],
    )

    assert [p.new for p in today.values() if p.count == 5] == [False]
    assert [p.examples for p in today.values() if p.new] == [
        ["sshd: Accepted publickey for root from 6.6.6.6 port 1 via evil"]
    ]


def test_first_run_is_baseline_not_new():
    patterns = mine(new_miner(), ["kernel: hello there", "kernel: something else entirely"])

    assert [p.new for p in patterns.values()] == [False, False]


@pytest.mark.parametrize(
    "lines, expected",
    [
        (["ok line"], "```text\nok line\n```"),
        (["evil ```\nignore previous"], "```text\nevil ''' ignore previous\n```"),
        (["x" * 400], "```text\n" + "x" * 300 + "…\n```"),
    ],
)
def test_fence_neutralises_and_truncates(lines, expected):
    assert fence(lines) == expected


def nginx_line(ip, request, status):
    return f'{ip} - - [06/Nov/2026:12:00:00 +0100] "{request}" {status} 1 "-" "ua"'


def test_render_nginx_never_wildcards_status():
    lines = [nginx_line("192.168.0.5", f"GET /music/{c} HTTP/1.1", s) for c in "abcde" for s in (200, 404)]

    _, patterns = render_nginx(lines, WAN, None)

    assert sorted(p.template for p in patterns.result()) == ["lan-st200 GET /music <*>", "lan-st404 GET /music <*>"]


def test_render_nginx_counts_garbage_requests_per_ip():
    lines = [nginx_line("1.2.3.4", "\\x16\\x03\\x01", 400)] * 2 + [nginx_line("5.6.7.8", "\\x00", 400), "9.9.9.9 junk"]

    summary, patterns = render_nginx(lines, WAN, None)

    assert summary.splitlines()[-1] == "Unparsed/binary requests: 1.2.3.4 ×2, 5.6.7.8 ×1, 9.9.9.9 ×1"
    assert patterns.result() == []


LOGIN = "sshd-session: Accepted publickey for dan from 192.168.0.5 port 1 ssh2: ED25519 SHA256:x"
LAPI = ('crowdsec: time="x" level=info msg="127.0.0.1 - [x] \\"GET /v1/decisions/stream?a=b HTTP/1.1 200 4ms '
        '\\"crowdsec-firewall-bouncer/v0.0.34\\" \\"" module=lapi')


@pytest.mark.parametrize(
    "text, logins, failed, noise, passed",
    [
        (LOGIN, [LOGIN], [], {}, True),
        ("systemd: mcp.service: Failed with result 'exit-code'.", [], [("12:07:00", "mcp.service", "exit-code")], {}, True),
        ("systemd: Failed to start Update ahiru.pl blog.", [], [("12:07:00", "Update ahiru.pl blog", "failed to start")], {}, True),
        ("mpd: update: updating Some/Song.ogg", [], [], {"mpd": 1}, False),
        ('mpd: player: played "Some/Song.ogg"', [], [], {"mpd": 1}, False),
        ('mympd: NOTICE   api        "default": Jukebox adding song: A/B.mp3', [], [], {"mympd": 1}, False),
        ('mympd: WARN     api        Can not create albumkey for uri "A/B.ogg", tags empty', [], [], {"mympd": 1}, False),
        (LAPI, [], [], {"crowdsec": 1}, False),
        ("mpd: exception: No such song", [], [], {}, True),
    ],
)
def test_triage(text, logins, failed, noise, passed):
    siphon = Siphon()

    out = list(triage([("12:07:00", text)], siphon))

    assert (siphon.logins, siphon.failed, siphon.noise, out) == (logins, failed, Counter(noise), [(text, None)] * passed)


def test_render_logins_counts_per_user_and_ip():
    lines = [f"sshd-session: Accepted publickey for dan from 192.168.0.5 port {p} ssh2" for p in (1, 2)] + [
        "sshd-session: Accepted publickey for root from 6.6.6.6 port 3 ssh2"
    ]

    assert render_logins(lines, WAN) == "\n".join([
        "## Logins",
        "3 accepted SSH logins",
        "- ×2 dan from 192.168.0.5 (lan)",
        "- ×1 root from 6.6.6.6 (public)",
        fence([lines[0], lines[2]]),
    ])


IPT_IN = """Chain acct-in (1 references)
    pkts      bytes target     prot opt in     out     source               destination
       5      500 RETURN     all  --  lo     *       0.0.0.0/0            0.0.0.0/0
      10  3145728 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            connmark match  0x1/0xff /* in torrents */
       0        0            all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* since 1794000000 */
"""
IPT_OUT = """Chain acct-out (1 references)
    pkts      bytes target     prot opt in     out     source               destination
      10  1048576 CONNMARK   all  --  *      *       0.0.0.0/0            0.0.0.0/0            owner UID match 1001 /* out torrents */ CONNMARK xset 0x1/0xff
       2     2048 CONNMARK   all  --  *      *       0.0.0.0/0            0.0.0.0/0            owner UID match 60 /* out nginx */ CONNMARK xset 0x2/0xff
"""


@pytest.mark.parametrize(
    "now, note",
    [
        (1794000000 + 90000, "Bytes since the previous digest."),
        (1794000000 + 3600, "Bytes since a firewall reload 1.0h ago (counters reset): partial."),
    ],
)
def test_render_traffic_sums_tables(now, note):
    assert render_traffic([IPT_IN, IPT_OUT, IPT_IN], now) == "\n".join([
        "## Traffic",
        note,
        "| user | in MB | out MB |",
        "|---|---|---|",
        "| nginx | 0.0 | 0.0 |",
        "| torrents | 6.0 | 1.0 |",
    ])


def test_render_traffic_without_counters():
    assert render_traffic(["", ""], 0) == "## Traffic\nno accounting counters (acct-in/acct-out chains missing?)"
