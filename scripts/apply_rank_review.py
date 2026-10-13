#!/usr/bin/env python3
"""Apply saved checkbox choices by source rank; keep nursery songs excluded."""
import argparse
import hashlib
import json
import zipfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
NURSERY_TITLES = {"きらきら星"}


def read_review(path, songs):
    expected = {s["rank"]: s for s in songs if not s["includedByDate"]}
    with zipfile.ZipFile(path) as archive:
        strings = ["".join(item.itertext()) for item in
                   ET.fromstring(archive.read("xl/sharedStrings.xml")).findall("s:si", NS)]
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        sheet = next(s for s in workbook.find("s:sheets", NS) if s.get("name") == "除外曲")
        rel_id = sheet.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id")
        relations = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        target = next(r.get("Target") for r in relations if r.get("Id") == rel_id)
        target = target.lstrip("/") if target.startswith("/") else "xl/" + target
        root = ET.fromstring(archive.read(target))

        def value(cell):
            node = cell.find("s:v", NS)
            if node is None:
                return None
            return strings[int(node.text)] if cell.get("t") == "s" else node.text

        decisions = {}
        for row in root.findall("s:sheetData/s:row", NS):
            if int(row.get("r")) < 7:
                continue
            cells = {c.get("r").rstrip("0123456789"): c for c in row.findall("s:c", NS)}
            if "A" not in cells or value(cells["A"]) is None:
                continue
            rank = int(float(value(cells["A"])))
            if rank not in expected or rank in decisions:
                raise ValueError(f"除外一覧の順位が重複または不正です: {rank}")
            original = expected[rank]
            if (value(cells["B"]), value(cells["C"]), value(cells["H"])) != (
                    original["title"], original["artist"], original["url"]):
                raise ValueError(f"元の曲情報と一致しません: {rank}位")
            checked = cells.get("F")
            if checked is None or checked.get("t") != "b" or value(checked) not in ("0", "1"):
                raise ValueError(f"チェック状態を確認してください: {rank}位")
            decisions[rank] = value(checked) == "1"
        if decisions.keys() != expected.keys():
            raise ValueError("除外455曲のチェック状態をすべて保存してください")
        return decisions


def apply_review(candidate, decisions, workbook_path):
    songs = candidate["songs"]
    for song in songs:
        song["addBack"] = decisions.get(song["rank"], False)
        song["excludedAsNursery"] = "童謡" in song["artist"] or song["title"] in NURSERY_TITLES
        song["selected"] = (song["includedByDate"] or song["addBack"]) and not song["excludedAsNursery"]
        song["selectionReason"] = ("童謡を除外" if song["excludedAsNursery"] else
                                   "ユーザーの追加チェック" if song["addBack"] else
                                   "掲載発売日が2010年以降" if song["includedByDate"] else "未選択")
    removed = [s for s in songs if s["excludedAsNursery"] and (s["includedByDate"] or s["addBack"])]
    selected = [s for s in songs if s["selected"]]
    counts = Counter(s["grade"] for s in selected)
    candidate["status"] = "review-applied-recordings-pending"
    candidate["review"] = {
        "workbook": str(workbook_path.relative_to(ROOT)),
        "sha256": hashlib.sha256(workbook_path.read_bytes()).hexdigest(),
        "appliedAt": datetime.now(timezone.utc).isoformat(),
        "checkedCount": sum(decisions.values()),
        "nurseryRemoved": [{k: s[k] for k in ("rank", "title", "artist", "sourceSongID")} for s in removed],
    }
    candidate["counts"]["reviewSelected"] = len(selected)
    candidate["counts"]["selectedByGrade"] = {g: counts[g] for g in candidate["counts"]["includedByGrade"]}
    return candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook", type=Path, default=ROOT / "outputs/utanet-rank-review-2026-10-13/除外曲一覧.xlsx")
    parser.add_argument("--candidates", type=Path, default=ROOT / "server/rank-catalog-candidates.json")
    args = parser.parse_args()
    candidate = json.loads(args.candidates.read_text())
    updated = apply_review(candidate, read_review(args.workbook, candidate["songs"]), args.workbook)
    args.candidates.write_text(json.dumps(updated, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"checked": updated["review"]["checkedCount"],
                      "nurseryRemoved": updated["review"]["nurseryRemoved"],
                      "selected": updated["counts"]["reviewSelected"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
