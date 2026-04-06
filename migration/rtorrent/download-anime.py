#!/usr/bin/env python3
import itertools
import re
import requests
from bs4 import BeautifulSoup
from pathlib import Path
from threading import Thread
from urllib.request import urlretrieve
from datetime import datetime

CURRENT_TIME_REGEX = b"A:\s*([\.\d]+) V:\s*[\.\d]+ A-V:\s*[-\.\d]+?"
ANIME_NAME_REGEX = "\[(?P<group>.*?)\]\s*(?P<title>.*?)[\s-]*(?P<episode>\d*?)\s*(END)?\s*(\[v\d+\])?(\[|\()(?P<quality>.*?)(\]|\)).*?\.mkv"
TORRENTS_BASE_URL = "https://nyaa.si"
DEEMED_WATCHED = 0.8
VIDEO_FILES = "[*mkv"
TRUSTED_GROUPS = {"SubsPlease", "Erai-raws"}

BASE_PATH = Path("/media/data/Unsorted")
HISTORY_FILE = BASE_PATH / ".anime_history"
HISTORY_FILE.touch()
STALLED_DIR = BASE_PATH / "stalled"
WATCH_DIR = BASE_PATH / ".watch/start"


def log(text):
    with open(BASE_PATH / ".log/download.log", "a") as fi:
        fi.write(f"{datetime.now().isoformat()} - {text}\n")


# Get stuff to watch


def seen():
    with open(HISTORY_FILE) as f:
        return map(Path, f.read().splitlines())


def unseen(with_skipped=False):
    files = set(BASE_PATH.glob(VIDEO_FILES))

    if with_skipped:
        skipped = set((BASE_PATH / "stalled").glob(VIDEO_FILES))
    else:
        skipped = set()

    return sorted(files - set(seen()) | skipped)


## Download stuff


def parse_episode(title):
    "Get episode information on the basis of the given video file name."
    title = re.match(ANIME_NAME_REGEX, title)
    if not title:
        return None

    episode_info = title.groupdict()
    episode_info["episode"] = (
        float(episode_info["episode"]) if episode_info["episode"] else -1
    )
    return episode_info


def parse_tag(tag):
    "Parse a single row of nyaa.si results."
    cat, name, download, size, date, seeds, leeches, status = tag.find_all("td")

    episode_info = parse_episode(name.find_all("a")[-1].get("title"))
    if episode_info:
        episode_info["torrent"] = TORRENTS_BASE_URL + download.find(
            "i", attrs={"class": "fa-download"}
        ).parent.attrs.get("href")
        episode_info["magnet"] = download.find(
            "i", attrs={"class": "fa-magnet"}
        ).parent.attrs.get("href")
    return episode_info


def download(episode):
    "Send a magnet link to Ktorrent."
    # time.sleep(random.randint(0, 15))
    # return subprocess.run(['ktorrent', episode['magnet']])
    torrent = episode["torrent"]
    return urlretrieve(torrent, WATCH_DIR / torrent.split("/")[-1])


def torrent_url(group, title, quality):
    if group in TRUSTED_GROUPS:
        query = "/user/{user}?f=0&c=0_0&q={title}+%5B{quality}%5D".format(
            user=group, title=title, quality=quality
        )
    else:
        query = "?f=0&c=0_0&q={user}+%5B{title}+%5B{quality}%5D".format(
            user=group, title=title, quality=quality
        )
    return TORRENTS_BASE_URL + query


def newer_episodes(group, title, episode, quality):
    "Look if there are any torrent files for episodes that are newer than the given episode."
    quality = "1080p"
    response = requests.get(torrent_url(group, title, quality))
    soup = BeautifulSoup(response.text)
    eps = [parse_tag(i) for i in soup.find_all("tr", attrs={"class": "success"})]
    eps = filter(
        lambda e: e and e["title"] == title and e["episode"] > float(episode), eps
    )
    return {ep["episode"]: ep for ep in eps}.values()


def missing_episodes(seen):
    "Return a list of episodes that should be downloaded."
    return (ep for newest in seen for ep in newer_episodes(**newest))


def newest_episode():
    """Return a list of the newest episodes of each series watched.

    Each episode is a dict, eg.:

       {'group': 'HorribleSubs',
        'title': 'Sword Art Online - Alicization',
        'episode': 11.0,
        'quality': '720p'}
    """
    eps = (parse_episode(video.name) for video in itertools.chain(seen(), unseen(True)))
    eps = {str(ep): ep for ep in eps}.values()
    eps = sorted(filter(None, eps), key=lambda e: e["title"])
    return [
        max(g, key=lambda e: e["episode"])
        for _, g in itertools.groupby(eps, lambda e: e["title"])
    ]


def check_torrents():
    """Look for any missing episodes and download them if any found."""
    missing = missing_episodes(newest_episode())
    for i, ep in enumerate(missing):
        log("Downloading [{group}] {title} - {episode} [{quality}]".format(**ep))
        download(ep)
    log(f"{i} new episodes found")


## Do stuff
log("looking for new episodes")
try:
    checker = Thread(target=check_torrents)
    checker.start()
    checker.join()
except Exception as e:
    log(e)
log("checked")
