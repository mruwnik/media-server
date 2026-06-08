"""mpd-rating: durable, portable song ratings for MPD.

Ratings live in two places, kept in sync:
  * the file's own tags (FMPS_RATING / POPM) -- the durable source of truth
    that travels with the file and survives player/database changes;
  * an MPD ``rating`` sticker (0-10, myMPD's convention) -- the working copy
    that myMPD and the MCP server can read/write without filesystem access.

Subcommands:
  rate <0-5> [uri]   rate the current track (or ``uri``); writes tag + sticker.
                     A rating of 1 also reaps (recoverably bins) and skips it.
  reap               sync every rated song's sticker into its file tag, then
                     bin every 1-star track. Meant for the hourly timer.
  restore [query]    move the most recently binned track (or one matching
                     ``query``) back into the library.
  list               list everything currently in the bin.

Paths come from MPD_MUSIC_DIR / MPD_BIN_DIR (defaults match the ahiru host).
"""
import argparse
import datetime
import os
import shutil
import socket
import sys

import mutagen
from mutagen.id3 import ID3, POPM, TXXX
from mutagen.id3._util import ID3NoHeaderError

MUSIC_ROOT = os.environ.get("MPD_MUSIC_DIR", "/media/data/Music")
BIN_ROOT = os.environ.get("MPD_BIN_DIR", "/media/data/Music.bin")
MPD_HOST = os.environ.get("MPD_HOST", "localhost")
MPD_PORT = int(os.environ.get("MPD_PORT", "6600"))
LEDGER = os.path.join(BIN_ROOT, ".removed.tsv")

# A rating of 1 star is the "bin me" signal.
REAP_STARS = 1
# Ratings that mean "noted, move on" — rate then skip to the next track.
SKIP_STARS = (2, 3)
POPM_EMAIL = "rating@ahiru"
# Star -> ID3 POPM byte (Banshee/Quod Libet buckets).
POPM_BYTES = {1: 1, 2: 64, 3: 128, 4: 196, 5: 255}


# --------------------------------------------------------------------------- #
# rating scale conversions
# --------------------------------------------------------------------------- #
def stars_to_sticker(stars):
    return stars * 2  # myMPD rating sticker is 0-10


def sticker_to_stars(value):
    return round(int(value) / 2)


def stars_to_fmps(stars):
    return stars / 5.0  # FMPS_RATING is a 0.0-1.0 float


def popm_to_stars(byte):
    for stars, threshold in ((5, 222), (4, 160), (3, 96), (2, 32), (1, 1)):
        if byte >= threshold:
            return stars
    return 0


# --------------------------------------------------------------------------- #
# minimal MPD protocol client
# --------------------------------------------------------------------------- #
class MPD:
    def __init__(self):
        self.sock = socket.create_connection((MPD_HOST, MPD_PORT), timeout=30)
        self.fh = self.sock.makefile("rwb")
        greeting = self.fh.readline()
        if not greeting.startswith(b"OK MPD"):
            raise RuntimeError(f"bad MPD greeting: {greeting!r}")

    def close(self):
        try:
            self.fh.close()
        finally:
            self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    @staticmethod
    def _quote(arg):
        return '"' + str(arg).replace("\\", "\\\\").replace('"', '\\"') + '"'

    def command(self, *parts):
        """Send one command, return response lines (raises on ACK)."""
        line = " ".join([parts[0]] + [self._quote(p) for p in parts[1:]])
        self.fh.write(line.encode() + b"\n")
        self.fh.flush()
        out = []
        while True:
            raw = self.fh.readline()
            if not raw:
                raise RuntimeError("MPD connection closed")
            text = raw.decode("utf-8", "replace").rstrip("\n")
            if text == "OK":
                return out
            if text.startswith("ACK"):
                raise MPDAck(text)
            out.append(text)

    def try_command(self, *parts):
        """Like command() but swallow ACK errors (e.g. missing sticker)."""
        try:
            return self.command(*parts)
        except MPDAck:
            return []


class MPDAck(RuntimeError):
    pass


def parse_kv(lines):
    result = {}
    for line in lines:
        if ": " in line:
            key, value = line.split(": ", 1)
            result[key] = value
    return result


# --------------------------------------------------------------------------- #
# file tag read/write
# --------------------------------------------------------------------------- #
def ext_of(path):
    return path.rsplit(".", 1)[-1].lower() if "." in path else ""


def write_tag(abspath, stars):
    """Write/clear the rating tag on a file (FMPS_RATING, plus POPM for mp3)."""
    ext = ext_of(abspath)
    if ext == "mp3":
        _write_mp3_tag(abspath, stars)
        return
    audio = mutagen.File(abspath)
    if audio is None:
        raise ValueError(f"unrecognised audio file: {abspath}")
    if stars > 0:
        audio["FMPS_RATING"] = f"{stars_to_fmps(stars):.3f}"
        audio["RATING"] = str(stars_to_sticker(stars))
    else:
        for key in ("FMPS_RATING", "RATING"):
            audio.pop(key, None)
    audio.save()


def _write_mp3_tag(abspath, stars):
    try:
        tags = ID3(abspath)
    except ID3NoHeaderError:
        tags = ID3()
    tags.delall("POPM")
    tags.delall("TXXX:FMPS_Rating")
    if stars > 0:
        tags.add(POPM(email=POPM_EMAIL, rating=POPM_BYTES[stars], count=0))
        tags.add(TXXX(encoding=1, desc="FMPS_Rating",
                      text=[f"{stars_to_fmps(stars):.3f}"]))
    tags.save(abspath)


def read_tag_stars(abspath):
    """Best-effort read of a rating from a file tag, as 0-5 stars or None."""
    ext = ext_of(abspath)
    if ext == "mp3":
        return _read_mp3_stars(abspath)
    audio = mutagen.File(abspath)
    if audio is None:
        return None
    if "FMPS_RATING" in audio:
        return round(float(audio["FMPS_RATING"][0]) * 5)
    if "RATING" in audio:
        return sticker_to_stars(audio["RATING"][0])
    return None


def _read_mp3_stars(abspath):
    try:
        tags = ID3(abspath)
    except (ID3NoHeaderError, Exception):
        return None
    for key in tags:
        if key.startswith("POPM"):
            return popm_to_stars(tags[key].rating)
    fmps = tags.getall("TXXX:FMPS_Rating")
    if fmps:
        return round(float(fmps[0].text[0]) * 5)
    return None


# --------------------------------------------------------------------------- #
# bin ledger
# --------------------------------------------------------------------------- #
def now_iso():
    return datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def read_ledger():
    if not os.path.exists(LEDGER):
        return []
    entries = []
    for line in open(LEDGER):
        line = line.rstrip("\n")
        if "\t" in line:
            entries.append(tuple(line.split("\t", 1)))
    return entries


def write_ledger(entries):
    os.makedirs(BIN_ROOT, exist_ok=True)
    with open(LEDGER, "w") as fh:
        for ts, rel in entries:
            fh.write(f"{ts}\t{rel}\n")


def append_ledger(rel):
    write_ledger(read_ledger() + [(now_iso(), rel)])


# --------------------------------------------------------------------------- #
# operations
# --------------------------------------------------------------------------- #
def queue_position(mpd, uri):
    """1-based queue position of the entry whose file == uri, or None."""
    on_match = False
    for line in mpd.command("playlistinfo"):
        if line.startswith("file: "):
            on_match = line[6:] == uri
        elif line.startswith("Pos: ") and on_match:
            return line[5:]
    return None


def update_db(mpd, rel):
    directory = os.path.dirname(rel)
    if directory:
        mpd.try_command("update", directory)
    else:
        mpd.try_command("update")


def reap_one(mpd, uri):
    """Recoverably bin one track: skip if playing, move file, drop from queue/DB."""
    current = parse_kv(mpd.command("currentsong")).get("file")
    if uri == current:
        mpd.try_command("next")
    pos = queue_position(mpd, uri)
    src = os.path.join(MUSIC_ROOT, uri)
    if os.path.exists(src):
        dest = os.path.join(BIN_ROOT, uri)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.move(src, dest)
        append_ledger(uri)
    if pos is not None:
        mpd.try_command("delete", pos)
    mpd.try_command("sticker", "delete", "song", uri, "rating")
    update_db(mpd, uri)


def cmd_rate(stars, uri):
    with MPD() as mpd:
        current = parse_kv(mpd.command("currentsong")).get("file", "")
        if not uri:
            uri = current
        if not uri:
            sys.exit("nothing is playing and no uri given")
        if stars > 0:
            mpd.command("sticker", "set", "song", uri, "rating", str(stars_to_sticker(stars)))
        else:
            mpd.try_command("sticker", "delete", "song", uri, "rating")
        abspath = os.path.join(MUSIC_ROOT, uri)
        if os.path.exists(abspath):
            write_tag(abspath, stars)
        print(f"rated {stars}* : {uri}")
        if stars == REAP_STARS:
            reap_one(mpd, uri)
            print(f"reaped -> {os.path.join(BIN_ROOT, uri)}")
        elif stars in SKIP_STARS and uri == current:
            mpd.try_command("next")
            print("skipped to next")


def find_rated(mpd):
    """Yield (uri, stars) for every song carrying a rating sticker."""
    uri = None
    for line in mpd.try_command("sticker", "find", "song", "", "rating"):
        if line.startswith("file: "):
            uri = line[6:]
        elif line.startswith("sticker: rating=") and uri is not None:
            yield uri, sticker_to_stars(line.split("rating=", 1)[1])
            uri = None


def cmd_reap():
    synced = reaped = 0
    with MPD() as mpd:
        rated = list(find_rated(mpd))
        for uri, stars in rated:
            abspath = os.path.join(MUSIC_ROOT, uri)
            if os.path.exists(abspath):
                try:
                    write_tag(abspath, stars)
                    synced += 1
                except Exception as exc:  # noqa: BLE001 - keep sweeping
                    print(f"  tag FAIL {uri}: {exc}", file=sys.stderr)
        for uri, stars in rated:
            if stars == REAP_STARS:
                reap_one(mpd, uri)
                reaped += 1
    print(f"reap: synced {synced} tag(s), binned {reaped} one-star track(s)")


def cmd_restore(query):
    entries = read_ledger()
    if not entries:
        sys.exit("bin ledger is empty")
    chosen = None
    for i in range(len(entries) - 1, -1, -1):
        if query is None or query.lower() in entries[i][1].lower():
            chosen = i
            break
    if chosen is None:
        sys.exit(f"no binned track matches {query!r}")
    _, rel = entries[chosen]
    src = os.path.join(BIN_ROOT, rel)
    if not os.path.exists(src):
        sys.exit(f"binned file missing: {src}")
    dest = os.path.join(MUSIC_ROOT, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.move(src, dest)
    del entries[chosen]
    write_ledger(entries)
    with MPD() as mpd:
        update_db(mpd, rel)
    print(f"restored: {rel}")


def cmd_list():
    entries = read_ledger()
    if not entries:
        print("(bin is empty)")
        return
    for ts, rel in entries:
        ok = os.path.exists(os.path.join(BIN_ROOT, rel))
        print(f"{ts}  [{'ok' if ok else 'MISSING'}]  {rel}")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="mpd-rating", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_rate = sub.add_parser("rate", help="rate current/given track")
    p_rate.add_argument("stars", type=int, choices=range(0, 6))
    p_rate.add_argument("uri", nargs="?", default="")

    sub.add_parser("reap", help="sync stickers to tags, then bin 1-star tracks")

    p_restore = sub.add_parser("restore", help="undo a binning")
    p_restore.add_argument("query", nargs="?", default=None)

    sub.add_parser("list", help="list binned tracks")

    args = parser.parse_args(argv)
    if args.cmd == "rate":
        cmd_rate(args.stars, args.uri)
    elif args.cmd == "reap":
        cmd_reap()
    elif args.cmd == "restore":
        cmd_restore(args.query)
    elif args.cmd == "list":
        cmd_list()


if __name__ == "__main__":
    main()
