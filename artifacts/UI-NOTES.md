# UI refresh

Preserved the existing Studio red, pink and white palette. Home centers a large IntoL wordmark with a static ECG-style waveform and the caption “シンプルイントロクイズ” above capsule buttons. Party and quiz choices crossfade in the same layout, preserving both button positions and sizes. The logo shrinks upward while the mode heading and Back control fade in. Later source-selection steps retain the three-step progress indicator.

Review uses a native List with staggered card entrances, persistent segment counts, circular check/return controls, and native trailing swipe deletion. Artwork follows a shrinking arc into the destination segment, which pops on arrival. Learning changes persist at the start of the animation; switching tabs or enabling Reduce Motion cancels only the decoration. The native delete action animates the row removal and also remains available to VoiceOver.

Friends shows notification disclosures only when invitations or requests exist. An empty state guides players into the multiplayer flow; populated friend lists use the main area without surrounding empty cards. The account header combines avatar, name, and inline editing. Focus expands the name field ring. Apple Music and iCloud use grouped settings rows with status badges, and explanatory text sits in section footers. All new spatial motion respects Reduce Motion; oversized text wraps and retains scrolling.

## References
- Apple iOS UI Kit: https://www.sketch.com/s/04c24d8b-38fb-4afb-8836-36617e022f02/symbols
- Official Apple Music icon, unchanged SVG from Apple Music_Icon_2020 / Color / RGB / Large: https://apple.co/am-icon-2020
- https://marketing.services.apple/apple-music-identity-guidelines

## Verification
- On 2026-10-03, XcodeBuildMCP built and launched the updated app on iPhone 17 Pro, iOS 26.5, with no build warnings or errors. Home and mode selection preserve capsule bounds; the final production build was launched again after verification.
- A separate local QA bundle with synthetic demo reviews, friends, requests, and invitations verified learning in both directions, updated counts, the flying artwork, the native accessibility delete action and row removal, compact notification disclosures, populated lists, and the room-creation route. Existing review data in the normal app was preserved.
- Checked 375pt-wide content, the largest Dynamic Type size, the Reduce Motion code paths, and inline name focus/commit. Live Apple Music playback, iCloud account synchronization, and multi-device multiplayer were outside this UI verification.
- Earlier screenshots and the video below document the 2026-09-28 layout; they have not been regenerated for this change.
- On 2026-09-28, XcodeBuildMCP built and launched the latest app on iPhone 16 Pro, iOS 18.6.
- [ui-demo.mp4](ui-demo.mp4) shows a room invitation arriving in the Friends tab, joining without entering a room code, the in-room Friends sheet and its Close button, solo practice, review, and account settings. Idle waits were removed from the recording.
- [friends.jpg](friends.jpg), [friend-request.jpg](friend-request.jpg), and [invite.jpg](invite.jpg) show the empty Friends tab, an incoming friend request, and an incoming room invitation.
- The friend request, approval, and invitation were exercised against the latest server running locally for the demo. The simulator app bundle used a local server URL; the repository's `.env` was not changed.
- Default text size: home, source selection, account settings and solo answer controls fit without scrolling.
- Apple Music subscription playback and multiplayer over multiple devices were not exercised.
- Startup showed an existing “Privacy acknowledgement required” service alert; dismissed for the local demo.
