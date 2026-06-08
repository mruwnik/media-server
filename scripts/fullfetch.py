"""fullfetch: replace a library track with the official full-length audio.

Generic tool. For each selected track it reads the file's artist/title tags,
searches YouTube (yt-dlp), and — only when the match clears a confidence gate
(trusted channel + artist/title match, sane duration) — downloads the official
audio and swaps it in *in place*. The path is preserved, so the track's MPD
rating sticker survives; the original is backed up (revertible) and dubious
matches are written to a review file instead of being applied.

Built for upgrading the TV-size animethemes haul to full songs, but it works on
any track that has artist/title tags.

Subcommands:
  fetch [--dir D | --all-rated] [--min-stars N] [--dry-run] [--limit N] [uri ...]
        Select tracks and upgrade them. With explicit uris, upgrade exactly
        those. Otherwise pick tracks rated >= --min-stars (default 2) under
        --dir (default: the anime haul), or anywhere with --all-rated.
        --dry-run shows the match it WOULD use without downloading/swapping.
  revert [query]
        Restore the most recently backed-up original (or one matching query).
  list  Show what's been upgraded (from the log).

Needs yt-dlp and ffmpeg on PATH.
"""
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import unicodedata

import mutagen

MUSIC = os.environ.get("MPD_MUSIC_DIR", "/media/data/Music")
DEFAULT_DIR = os.environ.get("FULLFETCH_DEFAULT_DIR", "Anime OPs & EDs (animethemes)")
BACKUP = os.environ.get("FULLFETCH_BACKUP_DIR", "/media/data/Music.fullfetch-backup")
LOG = os.path.expanduser("~/fullfetch.log")
REVIEW = os.path.expanduser("~/fullfetch_review.tsv")
MPD_HOST = os.environ.get("MPD_HOST", "localhost")
MPD_PORT = int(os.environ.get("MPD_PORT", "6600"))

MIN_FULL = 150           # reject matches shorter than this (still TV-size)
MAX_FULL = 600           # reject matches longer than this (compilation/wrong)
SKIP_OVER = 120          # leave tracks already longer than this (already full)
SEARCH_N = 5             # how many search hits to consider

# Channels we trust to be the real audio: artist "- Topic", anything "official",
# and the major J-music label channels that post official MVs/audio.
LABELS = ["avex", "lantis", "flyingdog", "sacra music", "sonymusic",
          "sony music", "king record", "pony canyon", "nbcuni", "vap",
          "nippon columbia", "warner music japan", "victor"]


# --------------------------------------------------------------------------- #
# minimal MPD client (stickers + update)
# --------------------------------------------------------------------------- #
class MPD:
    def __init__(self):
        self.sock = socket.create_connection((MPD_HOST, MPD_PORT), timeout=30)
        self.fh = self.sock.makefile("rwb")
        if not self.fh.readline().startswith(b"OK MPD"):
            raise RuntimeError("bad MPD greeting")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.fh.close()
        self.sock.close()

    @staticmethod
    def _q(arg):
        return '"' + str(arg).replace("\\", "\\\\").replace('"', '\\"') + '"'

    def cmd(self, *parts, ok_fail=False):
        line = " ".join([parts[0]] + [self._q(p) for p in parts[1:]])
        self.fh.write(line.encode() + b"\n")
        self.fh.flush()
        out = []
        while True:
            raw = self.fh.readline()
            if not raw:
                raise RuntimeError("MPD closed")
            text = raw.decode("utf-8", "replace").rstrip("\n")
            if text == "OK":
                return out
            if text.startswith("ACK"):
                if ok_fail:
                    return out
                raise RuntimeError(text)
            out.append(text)


def rated_uris(mpd, base, min_stars):
    """Yield uris under base (""=whole library) rated >= min_stars."""
    uri = None
    for line in mpd.cmd("sticker", "find", "song", base, "rating", ok_fail=True):
        if line.startswith("file: "):
            uri = line[6:]
        elif line.startswith("sticker: rating=") and uri:
            if round(int(line.split("rating=", 1)[1]) / 2) >= min_stars:
                yield uri
            uri = None


# --------------------------------------------------------------------------- #
# tags
# --------------------------------------------------------------------------- #
def safe_open(abspath, easy=False):
    """mutagen.File that returns None instead of raising on broken files."""
    try:
        return mutagen.File(abspath, easy=easy)
    except Exception:  # noqa: BLE001 - corrupt/empty files are expected here
        return None


def read_meta(abspath):
    audio = safe_open(abspath, easy=True)
    if audio is None:
        return "", "", ""
    artist = (audio.get("artist") or [""])[0]
    title = (audio.get("title") or [""])[0]
    album = (audio.get("album") or [""])[0]
    return artist, title, album


def parse_filename(uri):
    """Fallback artist/title from the filename when a file has no tags (e.g.
    0-byte/broken files). Handles 'Artist - Title' and the flat anime
    'Show - NN - OP/ED - Title' convention (title only, no artist)."""
    base = os.path.splitext(os.path.basename(uri))[0]
    parts = [p.strip() for p in base.split(" - ")]
    if (len(parts) >= 4 and re.match(r"^\d+$", parts[1])
            and re.match(r"^(OP|ED)", parts[2], re.I)):
        return "", parts[-1]
    if len(parts) == 2:
        return parts[0], parts[1]
    return "", base


def copy_tags(meta, dest):
    artist, title, album = meta
    audio = mutagen.File(dest, easy=True)
    if audio is None:
        return
    if title:
        audio["title"] = title
    if artist:
        audio["artist"] = artist
    if album:
        audio["album"] = album
    audio.save()


# --------------------------------------------------------------------------- #
# youtube match + download
# --------------------------------------------------------------------------- #
def search(query, n=SEARCH_N):
    proc = subprocess.run(
        ["yt-dlp", "-j", "--no-warnings", "--no-playlist", "--flat-playlist",
         f"ytsearch{n}:{query}"],
        capture_output=True, text=True,
    )
    cands = []
    for line in proc.stdout.splitlines():
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        cands.append({
            "id": d.get("id"),
            "title": d.get("title") or "",
            "channel": d.get("channel") or d.get("uploader") or "",
            "duration": d.get("duration") or 0,
            "url": d.get("url") or d.get("webpage_url") or "",
        })
    return cands


def norm(s):
    """Normalize for matching: NFKC, lowercase, keep only alnum + kana/kanji."""
    s = unicodedata.normalize("NFKC", s or "").lower()
    return re.sub(r"[^0-9a-z぀-ヿ一-鿿]+", "", s)


def classify(cand, artist, title):
    """Return (decision, reason): accept | review | reject."""
    dur = cand["duration"] or 0
    if not (MIN_FULL <= dur <= MAX_FULL):
        return "reject", f"duration {dur}s"
    chan = cand["channel"].lower()
    cand_title_n, cand_chan_n = norm(cand["title"]), norm(cand["channel"])
    trusted = ("topic" in chan or "official" in chan
               or any(norm(lbl) in cand_chan_n for lbl in LABELS))
    artist_n, title_n = norm(artist), norm(title)
    artist_match = bool(artist_n) and (artist_n in cand_title_n or artist_n in cand_chan_n)
    title_match = bool(title_n) and title_n in cand_title_n
    if trusted and (artist_match or title_match):
        return "accept", "trusted+" + ("artist" if artist_match else "title")
    if trusted or title_match or artist_match:
        sig = "+".join(s for s, ok in
                       [("trusted", trusted), ("title", title_match), ("artist", artist_match)] if ok)
        return "review", sig
    return "reject", "no signal"


def select(cands, artist, title):
    """Return (chosen_accept_or_None, review_candidates)."""
    review = []
    for c in cands:
        decision, reason = classify(c, artist, title)
        c["reason"] = reason
        if decision == "accept":
            return c, review
        if decision == "review":
            review.append(c)
    return None, review


def download(video_id, dest_noext):
    rc = subprocess.run(
        ["yt-dlp", "-x", "--audio-format", "opus", "--audio-quality", "0",
         "--no-warnings", "--no-playlist", "-o", dest_noext + ".%(ext)s",
         f"https://www.youtube.com/watch?v={video_id}"],
        capture_output=True, text=True,
    ).returncode
    out = dest_noext + ".opus"
    return out if rc == 0 and os.path.exists(out) else None


# --------------------------------------------------------------------------- #
# logs
# --------------------------------------------------------------------------- #
def log_line(fields):
    with open(LOG, "a") as fh:
        fh.write("\t".join(str(x).replace("\t", " ") for x in fields) + "\n")


def log_review(uri, query, cands):
    with open(REVIEW, "a") as fh:
        for c in cands:
            fh.write("\t".join(str(x).replace("\t", " ") for x in
                     [uri, query, c["reason"], c["duration"], c["channel"],
                      c["title"], c["url"]]) + "\n")


# --------------------------------------------------------------------------- #
# operations
# --------------------------------------------------------------------------- #
def upgrade_one(uri, dry_run, force=False):
    abspath = os.path.join(MUSIC, uri)
    if not os.path.exists(abspath):
        print(f"  skip (missing): {uri}")
        return False
    audio = safe_open(abspath)
    cur_len = audio.info.length if (audio and audio.info) else 0
    if not force and cur_len > SKIP_OVER:
        print(f"  skip (already full, {cur_len:.0f}s): {uri}")
        return False
    artist, title, album = read_meta(abspath)
    if not (artist or title):
        artist, title = parse_filename(uri)  # fallback for tagless/broken files
    if not title:
        print(f"  skip (no tags/name): {uri}")
        return False
    query = f"{artist} {title}".strip()
    chosen, review = select(search(query), artist, title)
    if not chosen:
        if review:
            b = review[0]
            print(f"  REVIEW: {query}\n      best: {b['duration']}s | {b['channel']} | {b['title']} ({b['reason']})")
            log_review(uri, query, review)
        else:
            print(f"  NO match: {query}")
            log_line(["nomatch", uri, query])
        return False
    info = f"{chosen['duration']}s | {chosen['channel']} | {chosen['title']} [{chosen['reason']}]"
    if dry_run:
        print(f"  ACCEPT: {query}\n      -> {info}")
        return True

    tmp = os.path.join("/tmp", "fullfetch-" + str(abs(hash(uri))))
    got = download(chosen["id"], tmp)
    if not got:
        print(f"  download FAILED: {query}")
        log_line(["dlfail", uri, query, chosen["url"]])
        return False
    backup = os.path.join(BACKUP, uri)
    os.makedirs(os.path.dirname(backup), exist_ok=True)
    shutil.move(abspath, backup)
    shutil.move(got, abspath)
    copy_tags((artist, title, album), abspath)
    print(f"  upgraded: {query}  ({chosen['duration']}s)")
    log_line(["upgraded", uri, query, chosen["duration"], chosen["channel"],
              chosen["title"], chosen["url"]])
    return True


def cmd_fetch(args):
    if args.from_file:
        uris = [ln.rstrip("\n") for ln in open(args.from_file) if ln.strip()]
        scope = args.from_file
    elif args.uris:
        uris = args.uris
        scope = "given uris"
    else:
        base = "" if args.all_rated else (args.dir or DEFAULT_DIR)
        scope = "whole library" if args.all_rated else (args.dir or DEFAULT_DIR)
        with MPD() as mpd:
            uris = list(rated_uris(mpd, base, args.min_stars))
    if args.limit:
        uris = uris[: args.limit]
    tag = "(dry-run) " if args.dry_run else ""
    print(f"{tag}{len(uris)} track(s) [{scope}, >={args.min_stars}*]")
    changed_dirs = set()
    matched = 0
    for uri in uris:
        if upgrade_one(uri, args.dry_run, args.force):
            matched += 1
            if not args.dry_run:
                changed_dirs.add(os.path.dirname(uri))
    if changed_dirs:
        with MPD() as mpd:
            for directory in changed_dirs:
                if directory:
                    mpd.cmd("update", directory, ok_fail=True)
                else:
                    mpd.cmd("update", ok_fail=True)
    print(f"\ndone: {matched}/{len(uris)} {'matched' if args.dry_run else 'upgraded'}")


def cmd_revert(args):
    if not os.path.isdir(BACKUP):
        sys.exit("no backups yet")
    matches = []
    for root, _, files in os.walk(BACKUP):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, BACKUP)
            if args.query is None or args.query.lower() in rel.lower():
                matches.append((os.path.getmtime(full), rel))
    if not matches:
        sys.exit(f"no backup matches {args.query!r}")
    matches.sort()
    _, rel = matches[-1]
    shutil.move(os.path.join(BACKUP, rel), os.path.join(MUSIC, rel))
    with MPD() as mpd:
        mpd.cmd("update", os.path.dirname(rel), ok_fail=True)
    print(f"reverted: {rel}")


def cmd_list(args):
    if not os.path.exists(LOG):
        print("(nothing fetched yet)")
        return
    for line in open(LOG):
        parts = line.rstrip("\n").split("\t")
        if parts and parts[0] == "upgraded":
            src = parts[5] if len(parts) > 5 else ""
            print(f"  {parts[3]}s  {parts[1]}  <- {src}")


def main(argv=None):
    p = argparse.ArgumentParser(prog="fullfetch", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="upgrade tracks to full-length")
    f.add_argument("--dir", default=None,
                   help="rated tracks under this folder (default: the anime haul)")
    f.add_argument("--all-rated", action="store_true",
                   help="all rated tracks in the library")
    f.add_argument("--min-stars", type=int, default=2)
    f.add_argument("--from-file", default=None,
                   help="read uris to upgrade from a file (one per line)")
    f.add_argument("--dry-run", action="store_true")
    f.add_argument("--force", action="store_true",
                   help=f"upgrade even if already longer than {SKIP_OVER}s")
    f.add_argument("--limit", type=int, default=0)
    f.add_argument("uris", nargs="*")
    r = sub.add_parser("revert", help="restore a backed-up original")
    r.add_argument("query", nargs="?", default=None)
    sub.add_parser("list", help="list upgraded tracks")
    args = p.parse_args(argv)
    {"fetch": cmd_fetch, "revert": cmd_revert, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    main()
