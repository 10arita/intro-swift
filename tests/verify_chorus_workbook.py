"""Validate the native Swift exporter with independent ZIP and XML readers."""
import sys
import zipfile
import xml.etree.ElementTree as ET
import csv
import io
import json
from pathlib import Path

root = Path(sys.argv[1])
ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
for filename, expected_rows in [("empty.xlsx", 1), ("records.xlsx", 3), ("bulk.xlsx", 601)]:
    with zipfile.ZipFile(root / filename) as archive:
        assert archive.testzip() is None
        for name in archive.namelist():
            ET.fromstring(archive.read(name))
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
    rows = sheet.findall("m:sheetData/m:row", ns)
    assert len(rows) == expected_rows
    assert sheet.find("m:autoFilter", ns).attrib["ref"] == f"A1:T{expected_rows}"
    assert not sheet.findall(".//m:f", ns), "Submitted text must never become formulas"
    if filename == "records.xlsx":
        cells = {cell.attrib["r"]: cell for row in rows for cell in row}
        def text(cell):
            value = cell.find("m:is/m:t", ns)
            return "" if value is None or value.text is None else value.text
        match = next(index for index in range(2, 4) if text(cells[f"H{index}"]) == "001234")
        assert text(cells[f"A{match}"]) == "=1+1"
        assert text(cells[f"B{match}"]) == "アーティスト & <歌> 😀"
        assert text(cells[f"C{match}"]) == 'アルバム "引用"'
        assert text(cells[f"O{match}"]) == '=HYPERLINK("test")\nメモ'
        assert float(cells[f"F{match}"].find("m:v", ns).text) == 72345
        assert float(cells[f"E{match}"].find("m:v", ns).text) == 72.345
        assert cells[f"H{match}"].attrib["t"] == "inlineStr", "Catalog IDs must stay literal strings"
print("Independent XLSX ZIP, XML, numeric timestamps, literal strings, and Unicode checks passed")

if len(sys.argv) > 2:
    with open(sys.argv[2], encoding="utf-16") as source:
        original = list(csv.DictReader(io.StringIO(source.read(), newline=""), delimiter="\t"))
    imported = json.loads((root / "actual-import.json").read_text())
    assert len(original) == len(imported) == 597
    for index, (left, right) in enumerate(zip(original, imported)):
        assert right["row"] == index + 2
        assert (right["title"], right["artist"], right["album"], right["durationSeconds"]) == (
            left["名前"], left["アーティスト"], left["アルバム"], int(left["時間"]))
    print("All 597 imported names, artists, albums, durations, and source rows match Python's independent TSV reader")

try:
    import openpyxl
except ImportError:
    pass
else:
    workbook = openpyxl.load_workbook(root / "records.xlsx")
    sheet = workbook["サビ位置"]
    assert sheet.max_row == 3 and sheet.max_column == 20
    assert sheet.freeze_panes == "D2"
    match = next(row for row in sheet.iter_rows(min_row=2) if row[7].value == "001234")
    assert match[0].value == "=1+1" and match[0].data_type == "s"
    assert match[5].value == 72345 and match[4].value == 72.345
    assert match[7].data_type == "s"
    workbook.close()
    print("openpyxl independently opened the workbook with correct text, numeric timestamps, styles, and freeze panes")
