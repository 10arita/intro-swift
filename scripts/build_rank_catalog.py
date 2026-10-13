#!/usr/bin/env python3
"""Build the reviewed Uta-Net bank from pinned recording metadata."""
import argparse
import hashlib
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = "jp-intro-utanet-2026-10-reviewed-v1"
LIMITS = [12, 8, 8, 5, 8, 5, 3, 5, 3, 3]
ARTIST_ALIASES = {
    "GReeeeN": ["GRe4N BOYZ"], "DOMOTO": ["KinKi Kids"],
    "Sexy Zone": ["timelesz"], "SUPER EIGHT": ["関ジャニ∞"],
    "三代目 J SOUL BROTHERS": ["三代目 J SOUL BROTHERS from EXILE TRIBE"],
    "GENERATIONS": ["GENERATIONS from EXILE TRIBE"], "Nissy(西島隆弘)": ["Nissy"],
    "ソナーポケット": ["Sonar Pocket"], "徳永英明": ["德永英明"],
    "松任谷由実": ["荒井由実"],
}

# Explicit equivalences verified in Apple's JP metadata. Never drop version or
# featured-vocalist words globally: they distinguish recordings of the same song.
SOURCE_ALIASES = {
    "213756": [("なんでもないや (movie ver.)", "RADWIMPS")],
    "237845": [("灰色と青 ( + 菅田将暉 )", "米津玄師 & 菅田 将暉")],
    "352487": [("さよーならまたいつか!- Sayonara", "米津玄師")],
    "253191": [("アイノカタチ (feat. HIDE)", "MISIA")],
    "230891": [("ピースサイン - Peace Sign", "米津玄師")],
    "328567": [("可愛くてごめん (feat. ちゅーたん(CV:早見沙織))", "HoneyWorks")],
    "191752": [("夜空。 (feat. Hazzie)", "miwa")],
    "199851": [("みんながみんな英雄 (フルバージョン)", "AI")],
    "206311": [("アインシュタインよりディアナ・アグロン", "なこみく & めるみお")],
    "250525": [("ヒプノシスマイク -Division Battle Anthem-", "ヒプノシスマイク -D.R.B- (Division All Stars)")],
    "283673": [("ヒプノシスマイク -Division Battle Anthem-+", "ヒプノシスマイク -D.R.B- (Division All Stars)")],
    "275263": [("ヒプノシスマイク -Division Rap Battle- +", "ヒプノシスマイク -D.R.B- (Division All Stars)")],
    "122918": [("HaruHaru (Japanese ver.)", "BIGBANG")],
    "224915": [("ロメオ", "LIP×LIP, 勇次郎 (CV:内山昂輝) & 愛蔵 (CV:島﨑信長)")],
    "162871": [("We Are Never Ever Getting Back Together (Japanese Ver.)", "MACO")],
    "238736": [("砂の惑星 ( + 初音ミク )", "米津玄師 & 初音ミク")],
    "273058": [("竈門炭治郎のうた (feat. 中川奈美)", "椎名 豪")],
    "270356": [("ホール・ニュー・ワールド (日本語版)", "中村倫也 & 木下晴香")],
    "53981": [("鱗", "秦基博")],
    "137375": [("それはやっぱり君でした", "二宮和也")],
    "115627": [("どこにでもある唄。", "二宮和也")],
    "198591": [("海の声", "桐谷健太")],
    "375655": [("革命道中 - On The Way", "アイナ・ジ・エンド")],
    "12950": [("丸ノ内サディスティック", "椎名林檎")],
    "310518": [("初心LOVE (うぶらぶ)", "なにわ男子")],
    "361347": [("オトノケ - Otonoke", "Creepy Nuts")],
    "51215": [("蕾 (つぼみ)", "コブクロ")],
    "31": [("愛燦燦 (あいさんさん)", "美空ひばり")],
    "191240": [("長く短い祭", "椎名林檎 & 浮雲"), ("長く短い祭", "椎名林檎と浮雲")],
    "19170": [("ココロオドル -original version-", "nobodyknows+")],
    "162126": [("ドーナツホール (COVER)", "米津玄師")],
    "345495": [("花になって - Be a flower", "緑黄色社会")],
    "359065": [("がらくた - JUNK", "米津玄師")],
    "263923": [("リメンバー・ミー (日本語歌)", "石橋陽彩")],
    "2568": [("少年時代 (Remastered 2018)", "井上陽水")],
    "350837": [("パジャマパーティーズのうた", "パジャマパーティーズ みどり(CV. 諸星すみれ)、ぴんく(CV. 長縄まりあ)、しろ(CV. 篠原侑)、むらさき(CV. 内山茉莉)")],
}


def normalized(text):
    return "".join(unicodedata.normalize("NFKC", text).lower().split())


def match_key(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text).casefold()
                   if c == "+" or unicodedata.category(c)[0] not in "PZS")


def artist_keys(artist):
    return {match_key(s) for s in [artist, *ARTIST_ALIASES.get(artist, [])]}


def matching_keys(source):
    keys = {(match_key(source["title"]), a) for a in artist_keys(source["artist"])}
    keys.update((match_key(title), match_key(artist))
                for title, artist in SOURCE_ALIASES.get(source.get("sourceSongID"), []))
    return keys


def is_alternate_recording(title, album):
    return re.search(r"(?i)(?:\blive\b|ライブ|\bconcert\b|\btour\b|コンサート|\bunplugged\b|\bremix\b|リミックス|\bacoustic\b|アコースティック|\binstrumental\b|\boff\s?vocal\b|カラオケ|オルゴール|弾き語り)",
                     title + " " + album) is not None


def recording_matches(source, recording):
    return ((match_key(recording["title"]), match_key(recording["artist"])) in matching_keys(source) and
            not is_alternate_recording(recording["title"], recording["album"]))


def build(candidate, recordings):
    if "review" not in candidate:
        raise ValueError("Apply the saved checkbox review first")
    selected = [s for s in candidate["songs"] if s.get("selected")]
    mapping = {r["sourceSongID"]: r for r in recordings["recordings"]}
    questions, pending, duplicate = [], [], []
    recording_ids = set()
    for source in selected:
        if source.get("excludedAsNursery"):
            raise ValueError("Nursery songs must not enter the rank bank")
        recording = mapping.get(source["sourceSongID"])
        if recording is None:
            pending.append(source)
            continue
        if not recording_matches(source, recording):
            raise ValueError(f"Recording does not match the selected song: {source['rank']}位")
        key = "\x1f".join(normalized(recording[k]) for k in ("title", "artist", "album"))
        if key in recording_ids:
            duplicate.append(source)
            continue
        recording_ids.add(key)
        level = source["level"]
        limit = LIMITS[level - 1]
        assert recording["durationMS"] > limit * 1000 and recording["album"]
        questions.append({
            "id": "rank-" + hashlib.sha256(f"{key}:{limit}".encode()).hexdigest()[:20],
            "recordingID": key,
            "title": recording["title"], "artist": recording["artist"], "album": recording["album"],
            "answerTitle": source["title"], "artistGroupID": normalized(source["artist"]),
            "catalogIDHint": recording.get("catalogIDHint"),
            "level": level, "difficulty": source["difficultyPrior"], "pushLimit": limit,
            "isClassic": source["releaseDate"] < "2010-01-01",
            "sourceSongID": source["sourceSongID"], "sourceRank": source["rank"],
            "sourceTitle": source["title"], "sourceArtist": source["artist"],
            "sourceURL": source["url"], "sourceReleaseDate": source["releaseDate"],
            "selectionReason": source["selectionReason"],
        })
    counts = Counter(q["level"] for q in questions)
    assert len(questions) >= 200 and all(counts[level] >= 20 for level in range(1, 11))
    assert counts[1] >= 23
    catalog = {"schemaVersion": 1, "version": VERSION, "provisional": True,
               "sourceURL": candidate["sourceURL"], "sourceExtractedAt": candidate["extractedAt"],
               "reviewSHA256": candidate["review"]["sha256"],
               "difficultyBasis": candidate["difficultyBasis"], "questions": questions}
    report = {"catalogVersion": VERSION, "selected": len(selected), "recordings": len(questions),
              "checkedAdditions": candidate["review"]["checkedCount"],
              "activeAdditions": sum(q["isClassic"] for q in questions),
              "byLevel": dict(sorted(counts.items())),
              "pending": [{k: s[k] for k in ("rank", "title", "artist", "sourceSongID", "url")} for s in pending],
              "duplicates": [{k: s[k] for k in ("rank", "title", "artist", "sourceSongID")} for s in duplicate],
              "nurseryRemoved": candidate["review"]["nurseryRemoved"]}
    return catalog, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path, default=ROOT / "server/rank-catalog-candidates.json")
    parser.add_argument("--recordings", type=Path, default=ROOT / "server/rank-recordings.json")
    args = parser.parse_args()
    candidate = json.loads(args.candidates.read_text())
    catalog, report = build(candidate, json.loads(args.recordings.read_text()))
    (ROOT / "server/rank-catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    (ROOT / "server/rank-catalog-selection.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    candidate["status"] = "active-with-pending-recordings" if report["pending"] else "active"
    candidate["activeCatalogVersion"] = VERSION
    candidate["counts"]["active"] = len(catalog["questions"])
    candidate["counts"]["recordingPending"] = len(report["pending"])
    args.candidates.write_text(json.dumps(candidate, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("pending", "duplicates")}, ensure_ascii=False))
    print(f"Pending recording matches: {len(report['pending'])}; duplicate recordings: {len(report['duplicates'])}")


if __name__ == "__main__":
    main()
