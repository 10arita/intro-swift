"""Generate six original, synthetic 30-second IntoL quiz clips.

No samples or third-party recordings are used. Generated WAV files are checked in.
"""

import math
import random
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RATE = 22050
DURATION = 30

PIECES = [
    ("yoake", 118, [0, 4, 7, 9, 7, 4, 2, 0], [0, 5, 9, 7]),
    ("kaze", 128, [7, 9, 11, 7, 4, 2, 4, 7], [0, 7, 5, 9]),
    ("aoi", 105, [0, 2, 4, 7, 11, 9, 7, 4], [0, 9, 5, 7]),
    ("haru", 135, [4, 7, 9, 12, 9, 7, 4, 2], [0, 5, 7, 0]),
    ("tsuki", 92, [9, 7, 4, 2, 0, 2, 4, 7], [9, 5, 0, 7]),
    ("hikari", 124, [0, 7, 9, 4, 12, 9, 7, 4], [0, 9, 7, 5]),
]


def note(semitone):
    return 220 * (2 ** (semitone / 12))


def synthesize(name, bpm, melody, chords, output):
    beat = 60 / bpm
    random.seed(name)
    with wave.open(str(output), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        chunk = bytearray()
        for sample in range(RATE * DURATION):
            t = sample / RATE
            step = int(t / (beat / 2))
            local = t % (beat / 2)
            root = chords[int(t / (beat * 4)) % len(chords)]
            lead = note(melody[step % len(melody)] + 12)
            bass = note(root - 12)
            envelope = min(1, local * 40) * math.exp(-local * 2.4)
            tone = envelope * (0.22 * math.sin(2 * math.pi * lead * t)
                               + 0.055 * math.sin(2 * math.pi * lead * 2 * t))
            tone += 0.11 * math.sin(2 * math.pi * bass * t) * math.exp(-(t % beat) * 2)
            tone += 0.055 * math.sin(2 * math.pi * note(root + 7) * t)
            kick_phase = t % beat
            tone += 0.18 * math.sin(2 * math.pi * (70 - 35 * kick_phase) * kick_phase) * math.exp(-kick_phase * 25)
            if int(t / beat) % 2:
                snare_phase = t % beat
                tone += 0.07 * (random.random() * 2 - 1) * math.exp(-snare_phase * 24)
            fade = min(1, t / 0.35, (DURATION - t) / 0.8)
            value = max(-1, min(1, tone * max(0, fade)))
            chunk.extend(int(value * 32767).to_bytes(2, "little", signed=True))
            if len(chunk) > 65536:
                wav.writeframes(chunk)
                chunk.clear()
        if chunk:
            wav.writeframes(chunk)


def main():
    app = ROOT / "IntoL" / "Audio"
    server = ROOT / "server" / "public" / "audio"
    app.mkdir(parents=True, exist_ok=True)
    server.mkdir(parents=True, exist_ok=True)
    for name, bpm, melody, chords in PIECES:
        output = app / f"{name}.wav"
        synthesize(name, bpm, melody, chords, output)
        (server / output.name).write_bytes(output.read_bytes())
        print(output.name, output.stat().st_size)
    cue = app / "push.wav"
    with wave.open(str(cue), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        frames = bytearray()
        for sample in range(int(RATE * 0.18)):
            t = sample / RATE
            envelope = min(1, t * 80) * math.exp(-t * 22)
            value = envelope * (0.42 * math.sin(2 * math.pi * 620 * t)
                                + 0.18 * math.sin(2 * math.pi * 930 * t))
            frames.extend(int(max(-1, min(1, value)) * 32767).to_bytes(2, "little", signed=True))
        wav.writeframes(frames)
    print(cue.name, cue.stat().st_size)


if __name__ == "__main__":
    main()
