#!/usr/bin/env python3
"""Prepare a review snapshot without activating a new Apple Music question bank."""

import argparse
import hashlib
import json
from collections import Counter
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GRADES = ["5級", "4級", "3級", "2級", "1級", "初段", "二段", "三段", "四段", "五段"]
CUTOFF = date(2010, 1, 1)


def prepare(snapshot):
    rows = snapshot["rows"]
    if len(rows) != 1000 or [r["rank"] for r in rows] != list(range(1, 1001)):
        raise ValueError("ランキング1〜1000位を重複・欠落なく用意してください")
    if len({r["url"] for r in rows}) != 1000:
        raise ValueError("曲ページが重複しています")

    songs = []
    for row in rows:
        release = date.fromisoformat(row["releaseDate"])
        if not row["title"] or not row["artist"] or not row["url"].startswith("https://www.uta-net.com/song/"):
            raise ValueError(f"曲情報を確認してください: {row['rank']}位")
        level = (row["rank"] - 1) // 100 + 1
        included = release >= CUTOFF
        songs.append({
            **row,
            "sourceSongID": row["url"].rstrip("/").split("/")[-1],
            "level": level,
            "grade": GRADES[level - 1],
            "difficultyPrior": round(-2.7 + (level - 1) * 0.6, 2),
            "includedByDate": included,
            "exclusionReason": None if included else "掲載発売日が2010年より前",
            "addBack": None,
        })

    counts = Counter(s["grade"] for s in songs if s["includedByDate"])
    return {
        "schemaVersion": 1,
        "version": "utanet-total-2026-10-13-review-v1",
        "status": "awaiting-exclusion-review",
        "sourceURL": snapshot["sourceURL"],
        "extractedAt": snapshot["extractedAt"],
        "sourceSHA256": hashlib.sha256(json.dumps(rows, ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        "releaseDateBasis": snapshot["releaseDateBasis"],
        "releaseDateCutoff": CUTOFF.isoformat(),
        "gradeRule": "元順位1〜100位を5級、以降100位ごとに1段階上げ、901〜1000位を五段。除外後も元順位を維持する。",
        "difficultyBasis": "累計歌詞アクセス順位による仮難度。イントロの識別難度・PUSH期限は未校正。",
        "activationRequirements": ["除外曲の追加希望を反映", "Apple Musicの録音を照合", "録音ごとのPUSH期限を確認"],
        "replacesCatalogVersion": "jp-intro-2026-10-provisional-v1",
        "counts": {"total": len(songs), "included": sum(s["includedByDate"] for s in songs),
                   "excluded": sum(not s["includedByDate"] for s in songs),
                   "includedByGrade": {grade: counts[grade] for grade in GRADES}},
        "songs": songs,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "server/rank-catalog-candidates.json")
    args = parser.parse_args()
    result = prepare(json.loads(args.snapshot.read_text()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["counts"], ensure_ascii=False))


if __name__ == "__main__":
    main()
