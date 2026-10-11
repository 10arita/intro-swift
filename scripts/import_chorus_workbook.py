#!/usr/bin/env python3
"""Validate a developer XLSX and produce the shared CloudKit catalog payload."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import unicodedata
import openpyxl


def normalize(value):
    return ''.join(unicodedata.normalize('NFKC', value).upper().split())


def convert(source):
    workbook = openpyxl.load_workbook(source, read_only=True, data_only=False)
    sheet = workbook['サビ位置']
    rows = list(sheet.values)
    headers = rows[0]
    required = {'名前', 'アーティスト', 'サビ開始MS', '曲長MS', '確認状態', '取得方法', '確認日時UTC', 'musicID'}
    if not required.issubset(headers):
        raise ValueError('Required developer workbook columns are missing')
    mapping = {'名前': 'title', 'アーティスト': 'artist', 'アルバム': 'album', 'catalogID': 'catalogID',
               'libraryID': 'libraryID', 'storefront': 'storefront', 'ISRC': 'isrc', 'musicID': 'musicID',
               '確認日時UTC': 'checkedAt', '取得方法': 'method', 'メモ': 'notes', 'プレイリスト': 'playlist',
               '元の名前': 'sourceTitle', '元のアーティスト': 'sourceArtist'}
    records, seen = [], set()
    for row_number, row in enumerate(rows[1:], 2):
        if not any(value is not None for value in row):
            continue
        raw = dict(zip(headers, row))
        if raw['確認状態'] != '確認済み' or raw['取得方法'] != 'manual-apple-music':
            raise ValueError(f'Row {row_number}: not a manually confirmed submission')
        record = {key: str(raw.get(column) or '') for column, key in mapping.items()}
        for column, key in [('サビ開始MS', 'chorusStartMS'), ('曲長MS', 'durationMS')]:
            value = raw[column]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value != int(value):
                raise ValueError(f'Row {row_number}: invalid {column}')
            record[key] = int(value)
        if not 0 <= record['chorusStartMS'] < record['durationMS']:
            raise ValueError(f'Row {row_number}: timestamp outside recording')
        key = (normalize(record['title']), normalize(record['artist']))
        if not all(key) or key in seen:
            raise ValueError(f'Row {row_number}: empty or duplicate title/artist key')
        seen.add(key)
        record['sourceRow'] = raw.get('元の行')
        record['workbookRow'] = row_number
        records.append(record)
    workbook.close()
    if not records:
        raise ValueError('No confirmed submissions')
    return {'schemaVersion': 1, 'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'recordCount': len(records), 'records': records}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    catalog = convert(args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(args.output)
    print(f"Validated and imported {catalog['recordCount']} confirmed recordings")


if __name__ == '__main__':
    main()
