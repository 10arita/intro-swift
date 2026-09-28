# UI refresh

Preserved the existing Studio red, pink and white palette. Compact selection rows, a direct practice action, a three-step progress indicator, and segmented account settings reduce vertical navigation. Shared primary buttons use a short spring press response; tab changes crossfade and respect Reduce Motion. Solo listening, answers and reveal use smaller spacing and artwork. Long collections and large text retain scrolling.

## References
- Apple iOS UI Kit: https://www.sketch.com/s/04c24d8b-38fb-4afb-8836-36617e022f02/symbols
- Official Apple Music icon, unchanged SVG from Apple Music_Icon_2020 / Color / RGB / Large: https://apple.co/am-icon-2020
- https://marketing.services.apple/apple-music-identity-guidelines

## Verification
- On 2026-09-28, XcodeBuildMCP built and launched the latest app on iPhone 16 Pro, iOS 18.6.
- [ui-demo.mp4](ui-demo.mp4) shows a room invitation arriving in the Friends tab, joining without entering a room code, the in-room Friends sheet and its Close button, solo practice, review, and account settings. Idle waits were removed from the recording.
- [friends.jpg](friends.jpg), [friend-request.jpg](friend-request.jpg), and [invite.jpg](invite.jpg) show the empty Friends tab, an incoming friend request, and an incoming room invitation.
- The friend request, approval, and invitation were exercised against the latest server running locally for the demo. The simulator app bundle used a local server URL; the repository's `.env` was not changed.
- Default text size: home, source selection, account settings and solo answer controls fit without scrolling.
- Apple Music subscription playback and multiplayer over multiple devices were not exercised.
- Startup showed an existing “Privacy acknowledgement required” service alert; dismissed for the local demo.
