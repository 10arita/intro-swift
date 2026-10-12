"""Export Xcode app icon sizes from a finished, opaque square PNG using macOS sips."""

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "IntoL" / "Assets.xcassets" / "AppIcon.appiconset"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=OUT / "AppIcon.png")
    args = parser.parse_args()
    source = args.source.resolve()
    if not source.is_file():
        parser.error(f"Source image does not exist: {source}")

    properties = subprocess.check_output(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(source)],
        text=True,
    )
    fields = dict(line.strip().split(": ", 1) for line in properties.splitlines() if ": " in line)
    if fields.get("pixelWidth") != fields.get("pixelHeight"):
        parser.error("The source image must be square.")
    if fields.get("hasAlpha") != "no":
        parser.error("The source image must be opaque, with no alpha channel.")

    catalog = json.loads((OUT / "Contents.json").read_text())
    with tempfile.TemporaryDirectory(prefix="intol-app-icon-") as directory:
        staged = Path(directory)
        for image in catalog["images"]:
            filename = image.get("filename")
            if not filename:
                continue
            points = float(image["size"].split("x")[0])
            scale = float(image["scale"].removesuffix("x"))
            pixels = str(round(points * scale))
            subprocess.run(
                ["sips", "-z", pixels, pixels, str(source), "--out", str(staged / filename)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        for path in sorted(staged.iterdir()):
            destination = OUT / path.name
            shutil.copyfile(path, destination)
            print(destination)


if __name__ == "__main__":
    main()
