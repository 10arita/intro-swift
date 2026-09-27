"""Refresh the title-only quiz corpus from Billboard JAPAN's public charts.

The output contains no rankings or artist metadata. Source charts: Japan Hot 100
year-end 2015–2025 and selected weekly Japan Hot 100 charts through Sep 2026.
"""

import datetime as dt
import html
import json
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "server/corpus/famousSongsChart2015Plus.json"
BASE = "https://www.billboard-japan.com/charts/detail?a="
EXCLUDED_ARTISTS = {
    "BTS", "TWICE", "BLACKPINK", "NewJeans", "LE SSERAFIM", "aespa", "ILLIT",
    "SEVENTEEN", "Stray Kids", "ENHYPEN", "TOMORROW X TOGETHER", "TXT",
    "Jung Kook", "Jimin", "V", "J-Hope", "JIN", "RM", "NCT 127", "NCT DREAM",
    "NCT U", "IVE", "ITZY", "(G)I-DLE", "i-dle", "Kep1er", "KARA", "BIGBANG",
    "PSY", "EXO", "SHINee", "2PM", "TREASURE", "TWS", "BOYNEXTDOOR",
    "Ed Sheeran", "Taylor Swift", "Maroon 5", "Bruno Mars", "Ariana Grande",
    "Justin Bieber", "The Weeknd", "One Direction", "Coldplay", "Dua Lipa",
    "Charlie Puth", "Lady Gaga", "Billie Eilish", "Post Malone", "Adele",
    "Sam Smith", "Olivia Rodrigo", "HUNTR/X", "Sabrina Carpenter", "Benson Boone",
    "エド・シーラン", "テイラー・スウィフト", "マルーン5", "ブルーノ・マーズ",
    "アリアナ・グランデ", "ジャスティン・ビーバー", "ザ・ウィークエンド",
    "ビリー・アイリッシュ", "レディー・ガガ", "ワン・ダイレクション",
    "ケイティ・ペリー", "アデル", "チャーリー・プース", "コールドプレイ",
    "防弾少年団", "BTS (防弾少年団)", "BLACKPINK", "TWICE(トゥワイス)",
}


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "IntoL-corpus/1.0"})
    return urllib.request.urlopen(request, timeout=20).read().decode("utf-8", "replace")


def entries(page):
    for item in re.finditer(r'<tr class="rank(\d+)".*?</tr>', page, re.S):
        title = re.search(r'<p class="musuc_title">(.*?)</p>', item.group(), re.S)
        artist = re.search(r'<p class="artist_name">(.*?)</p>', item.group(), re.S)
        if not title or not artist:
            continue
        clean = lambda raw: " ".join(html.unescape(re.sub(r"<[^>]+>", "", raw)).split())
        yield int(item.group(1)), clean(title.group(1)), clean(artist.group(1))


def monday(year, month):
    day = dt.date(year, month, 8)
    return day + dt.timedelta(days=(0 - day.weekday()) % 7)


def main():
    score = {}
    sources = []
    for year in range(2015, 2026):
        sources.append((f"{BASE}hot100_year&year={year}", True))
    for year in range(2015, 2027):
        months = (1, 4, 7, 10) if year < 2026 else (1, 3, 5, 7, 9)
        for month in months:
            day = monday(year, month)
            sources.append((f"{BASE}hot100&year={day.year}&month={day.month:02d}&day={day.day:02d}", False))
    sources.append((f"{BASE}hot100", False))

    for url, annual in sources:
        rows = list(entries(fetch(url)))
        if len(rows) < 50:
            raise RuntimeError(f"Chart has only {len(rows)} rows: {url}")
        for rank, title, artist in rows:
            if not title or artist in EXCLUDED_ARTISTS or (not annual and rank > 50):
                continue
            score[title] = score.get(title, 0) + (1000 if annual else 250) / (rank + 10)

    existing = set()
    for name in ("famousSongs.json", "famousSongsJapaneseExpansion.json", "famousSongsJpop2015Plus.json"):
        existing.update(json.loads((OUTPUT.parent / name).read_text()))
    titles = [title for title, _ in sorted(score.items(), key=lambda item: (-item[1], item[0]))
              if title not in existing]
    OUTPUT.write_text(json.dumps(titles[:1100], ensure_ascii=False, indent=2) + "\n")
    print(f"{len(titles)} distinct new titles; wrote {min(1100, len(titles))} to {OUTPUT}")


if __name__ == "__main__":
    main()
