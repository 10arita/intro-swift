Generated with the built-in image_gen tool, using the previous app icon as the edit target.

Use case: precise-object-edit.
Asset type: finished iOS app icon for IntoL, a Japanese music intro guessing quiz.
Input image: existing app icon, edit target and reference for its centered audio waveform motif.
Primary request: redesign this icon to be very simple, predominantly white, with a small strong red accent.
Scene/backdrop: full bleed perfectly flat pure white #FFFFFF square, opaque, no border, no pre-rounded outer corners.
Subject: one centered red audio waveform formed by FIVE separate solid vertical capsule-shaped bars. Bar heights form a symmetrical short / medium / tall / medium / short sequence. Every bar has the same width and rounded ends, with generous equal gaps. Use deep warm crimson #BA1421, matching the app accent. Remove the embedded play triangle completely; all five bars must be uninterrupted solid red capsules.
Composition: five-bar mark centered horizontally and vertically. Entire mark occupies approximately 50 percent of the square width and 48 percent of square height, with generous white negative space around it. Red should cover less than 20 percent of the image. Crisp edges, precise balanced geometry, immediately legible at small home-screen icon sizes.
Style: clean two-color flat vector-like graphic.
Constraints: retain the recognizable waveform idea only; use white background and red waveform. No lettering, text, triangle, rings, frame, decorative marks, texture, glow, gradient, shadows, bevel, 3D, device mockup, Apple or Apple Music logo, or transparency. Deliver only the square icon artwork, ideally 1024 x 1024.

Installed in IntoL/Assets.xcassets/AppIcon.appiconset at 1024, 180, 120, 87, 80, 60, 58, and 40 pixels. All PNG images are opaque RGB images. The app target uses this AppIcon catalog for both Debug and Release.

To export all catalog sizes again from the installed 1024-pixel master:

```sh
python3 scripts/generate_app_icon.py
```

To install a new opaque square PNG and export all sizes:

```sh
python3 scripts/generate_app_icon.py --source /absolute/path/to/icon.png
```

The export script resizes the finished artwork with macOS sips; it does not redraw or recolor the icon.
