# UI refresh

Preserved the existing Studio red, pink and white palette. Compact selection rows, a direct practice action, a three-step progress indicator, and segmented account settings reduce vertical navigation. Shared primary buttons use a short spring press response; tab changes crossfade and respect Reduce Motion. Solo listening, answers and reveal use smaller spacing and artwork. Long collections and large text retain scrolling.

## References
- Apple iOS UI Kit: https://www.sketch.com/s/04c24d8b-38fb-4afb-8836-36617e022f02/symbols
- Official Apple Music icon, unchanged SVG from Apple Music_Icon_2020 / Color / RGB / Large: https://apple.co/am-icon-2020
- https://marketing.services.apple/apple-music-identity-guidelines

## Verification
- XcodeBuildMCP build and launch passed on iPhone 16 Pro, iOS 18.6.
- Demonstrated practice launch, countdown, listening, PUSH, answering, reveal, review save, review tab, account settings and source selection. See ui-demo.mp4.
- Default text size: home, source selection, account settings and solo answer controls fit without scrolling.
- Apple Music subscription playback and multiplayer over multiple devices were not exercised.
- Startup showed an existing “Privacy acknowledgement required” service alert; dismissed for the local demo.
- Existing project.pbxproj working changes were preserved.
