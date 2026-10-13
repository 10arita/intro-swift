#!/usr/bin/env python3
"""Rebuild the provisional, recording-specific bank from the existing manual catalog.

The groups are editorial starting estimates, NOT measured item difficulties.
Review the actual intro before replacing these priors with calibrated values.
"""
import hashlib
import json
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GROUPS = [
    [0,52,56,83,93,94,153,162,209,215,242,270,306,327,339,389,493,560,576,76,18,161,151],
    [95,182,84,31,218,287,300,312,371,13,19,29,46,117,151,161,68,206,213,349],
    [18,20,28,50,54,252,204,81,123,96,101,111,120,140,149,328,382,201,240,244],
    [2,3,238,239,60,62,74,82,402,85,110,112,171,172,174,176,260,267,211,216],
    [228,248,16,343,39,229,233,337,65,67,79,118,152,164,179,180,237,332,210,214],
    [217,449,14,49,230,231,58,234,235,194,262,263,314,315,330,331,355,15,250,251],
    [347,348,202,48,51,335,308,336,203,269,271,273,274,276,279,282,507,289,290,291],
    [292,297,298,436,302,303,264,265,322,310,311,196,329,241,243,353,354,318,319,320],
    [309,323,324,326,442,313,245,246,198,358,370,307,63,266,338,340,66,257,351,352],
    [316,317,247,356,357,333,334,141,377,378,379,200,384,395,400,401,405,407,408,409],
]
CLASSICS = {76,123,182,402,343,449,507,436,442,141}
LIMITS = [12,8,8,5,8,5,3,5,3,3]

def normalized(text):
    return "".join(unicodedata.normalize("NFKC", text).lower().split())

def build():
    source = json.loads((ROOT / "server/manual-chorus.json").read_text())
    # Positional editorial groups must be reviewed if the source workbook changes.
    assert source["sourceSHA256"] == "5cdd0d808f2b682803981e2a5fd6a20313fa8248898e995add61d3e37c2c0ec6", "Review editorial groups against the changed workbook"
    records = source["records"]
    questions = []
    for level, indices in enumerate(GROUPS, 1):
        assert len(indices) >= 20
        for index in indices:
            record = records[index]
            key = "\x1f".join(normalized(record[k]) for k in ["title", "artist", "album"])
            limit = LIMITS[level - 1]
            question_id = "rank-" + hashlib.sha256(f"{key}:{limit}".encode()).hexdigest()[:20]
            questions.append(dict(id=question_id, recordingID=key, title=record["title"],
                                  artist=record["artist"], album=record["album"],
                                  catalogIDHint=record.get("catalogID") or None,
                                  level=level, difficulty=round(-2.7 + (level-1)*0.6, 2),
                                  pushLimit=limit, isClassic=index in CLASSICS))
    assert len({q["recordingID"] for q in questions}) == 200
    return dict(schemaVersion=1, version="jp-intro-2026-10-provisional-v1",
                provisional=True, questions=questions)

if __name__ == "__main__":
    destination = ROOT / "server/rank-catalog.json"
    destination.write_text(json.dumps(build(), ensure_ascii=False, indent=2) + "\n")
    print("Wrote 203 provisional tasks / 200 recordings (23 warmups, 20 in each other level, 10 classics).")
