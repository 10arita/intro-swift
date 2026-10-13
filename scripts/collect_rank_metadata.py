#!/usr/bin/env python3
"""Read Apple JP metadata at <=19 API requests/minute; never download audio."""
import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from build_rank_catalog import ROOT, ARTIST_ALIASES, artist_keys, match_key, recording_matches, is_alternate_recording, matching_keys

FIELDS = ("trackId", "trackName", "artistName", "artistId", "collectionId", "collectionName",
          "releaseDate", "trackTimeMillis", "primaryGenreName", "trackViewUrl")


def write_json(path, data, indent=None):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=indent) + "\n")
    temporary.replace(path)


class AppleMetadata:
    def __init__(self, cache_path):
        self.path = cache_path
        self.cache = json.loads(self.path.read_text()) if self.path.exists() else {}
        self.last_call = 0

    def query(self, endpoint, **params):
        params = {"country": "JP", "lang": "ja_jp", **params}
        url = "https://itunes.apple.com/" + endpoint + "?" + urllib.parse.urlencode(params)
        if url in self.cache:
            return self.cache[url]["tracks"], url
        for attempt in range(3):
            time.sleep(max(0, 3.2 - (time.monotonic() - self.last_call)))
            self.last_call = time.monotonic()
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "IntoL-rank-metadata/1.0"})
                with urllib.request.urlopen(request, timeout=20) as response:
                    result = json.load(response)
                tracks = [{k: r[k] for k in FIELDS if k in r} for r in result.get("results", [])
                          if r.get("kind") == "song" and r.get("trackId") and r.get("collectionName")]
                self.cache[url] = {"checkedAt": datetime.now(timezone.utc).isoformat(), "tracks": tracks}
                self.path.parent.mkdir(parents=True, exist_ok=True)
                write_json(self.path, self.cache)
                return tracks, url
            except (urllib.error.URLError, TimeoutError) as error:
                print(f"Metadata request retry {attempt + 1}: {type(error).__name__}", flush=True)
                if attempt == 2:
                    raise
                time.sleep(15 if isinstance(error, urllib.error.HTTPError) and error.code == 429 else 4)


def apple_record(track, url, checked_at):
    return {"title": track["trackName"], "artist": track["artistName"], "album": track["collectionName"],
            "catalogIDHint": str(track["trackId"]), "durationMS": track.get("trackTimeMillis", 0),
            "matchedBy": "apple-jp-metadata", "sourceURL": url, "checkedAt": checked_at,
            "releaseDate": track.get("releaseDate", ""), "artistID": track.get("artistId")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path("/private/tmp/intol-rank-itunes-cache.json"))
    parser.add_argument("--cache-only", action="store_true", help="Re-evaluate downloaded metadata without network requests")
    args = parser.parse_args()
    apple = AppleMetadata(args.cache)
    selected = [s for s in json.loads((ROOT / "server/rank-catalog-candidates.json").read_text())["songs"] if s.get("selected")]
    manual = json.loads((ROOT / "server/manual-chorus.json").read_text())["records"]
    now = datetime.now(timezone.utc).isoformat()
    all_tracks, result = {}, {}
    track_index = defaultdict(dict)
    for source in selected:
        candidates = [r for r in manual if recording_matches(source, r)]
        if candidates:
            r = candidates[0]
            result[source["sourceSongID"]] = {"sourceSongID": source["sourceSongID"],
                "title": r["title"], "artist": r["artist"], "album": r["album"],
                "catalogIDHint": None, "durationMS": r["durationMS"],
                "matchedBy": "manual-apple-music-metadata", "checkedAt": r["checkedAt"],
                "sourceURL": "server/manual-chorus.json"}

    def save():
        write_json(ROOT / "server/rank-recordings.json", {
            "schemaVersion": 1, "storefront": "jp", "collectedAt": now,
            "recordings": [result[s["sourceSongID"]] for s in selected if s["sourceSongID"] in result],
        }, indent=2)

    def absorb(tracks, url):
        for track in tracks:
            origin = url if url is not None else all_tracks[track["trackId"]][1]
            all_tracks[track["trackId"]] = (track, origin)
            if not is_alternate_recording(track["trackName"], track["collectionName"]):
                track_index[(match_key(track["trackName"]), match_key(track["artistName"]))][track["trackId"]] = (track, origin)
        for source in selected:
            matches = [(t, u) for key in matching_keys(source)
                       for t, u in track_index[key].values()
                       if t.get("trackTimeMillis", 0) > 12000]
            if matches:
                # Prefer a known album, otherwise the earliest studio release.
                old_album = result.get(source["sourceSongID"], {}).get("album")
                t, u = min(matches, key=lambda pair: (pair[0]["collectionName"] != old_album,
                           pair[0].get("releaseDate", "9999"), pair[0]["trackId"]))
                checked_at = apple.cache.get(u, {}).get("checkedAt", now)
                result[source["sourceSongID"]] = {"sourceSongID": source["sourceSongID"], **apple_record(t, u, checked_at)}
        save()

    save()
    print(f"Existing Apple Music recording metadata: {len(result)}/{len(selected)}", flush=True)
    if apple.cache:
        for url, entry in apple.cache.items():
            for track in entry["tracks"]:
                all_tracks[track["trackId"]] = (track, url)
        absorb([t for t, _ in all_tracks.values()], None)
    if args.cache_only:
        print(f"Cached metadata pinned {len(result)}/{len(selected)} recordings.", flush=True)
        return
    ids = sorted({int(r["catalogID"]) for r in manual if str(r.get("catalogID", "")).isdigit()
                  and 100_000_000 <= int(r["catalogID"]) <= 2_147_483_647})
    for offset in range(0, len(ids), 150):
        tracks, url = apple.query("lookup", id=",".join(map(str, ids[offset:offset+150])))
        absorb(tracks, url)
    print(f"After numeric-ID checks: {len(result)}/{len(selected)}", flush=True)

    wanted_artists = set().union(*(artist_keys(s["artist"]) for s in selected if s["sourceSongID"] not in result))
    artist_ids = sorted({t["artistId"] for t, _ in all_tracks.values()
                         if t.get("artistId") and match_key(t["artistName"]) in wanted_artists})
    for offset in range(0, len(artist_ids), 10):
        tracks, url = apple.query("lookup", id=",".join(map(str, artist_ids[offset:offset+10])), entity="song", limit=200)
        absorb(tracks, url)
    print(f"After artist-ID batches: {len(result)}/{len(selected)}", flush=True)

    artists = list(dict.fromkeys(s["artist"] for s in selected if s["sourceSongID"] not in result))
    for i, artist in enumerate(artists, 1):
        if not any(s["artist"] == artist and s["sourceSongID"] not in result for s in selected):
            continue
        tracks, url = apple.query("search", term=artist, media="music", entity="song", attribute="artistTerm", limit=200)
        absorb(tracks, url)
        if i % 5 == 0 or i == len(artists):
            print(f"Artist searches {i}/{len(artists)}; matched {len(result)}/{len(selected)}", flush=True)

    missing = [s for s in selected if s["sourceSongID"] not in result]
    for i, source in enumerate(missing, 1):
        term_artist = ARTIST_ALIASES.get(source["artist"], [source["artist"]])[0]
        tracks, url = apple.query("search", term=source["title"] + " " + term_artist,
                                 media="music", entity="song", limit=25)
        absorb(tracks, url)
        if i % 5 == 0 or i == len(missing):
            print(f"Specific song searches {i}/{len(missing)}; matched {len(result)}/{len(selected)}", flush=True)
    save()
    print(f"Pinned {len(result)}/{len(selected)} recordings; {len(selected)-len(result)} remain unmatched.", flush=True)


if __name__ == "__main__":
    main()
