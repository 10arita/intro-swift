# UI refresh

The play flow keeps the Studio red, pink and white palette. Home retains the IntoL wordmark and waveform, and uses taller music cards with descriptions and a single centered icon. Solo proceeds through quiz mode and Apple Music playlist selection. Multiplayer branches into creating a room or entering a code before choosing any quiz mode. The headings are “ルーム選択” and “モード選択”, and the Sabitro card uses “SABITRO”. Host mode selection creates a deferred-question room directly; playlists and rules stay in the lobby. Original-audio, shared-audio and preview-song-search choices have been removed from this flow.

Each forward/back step uses a horizontal shared-axis transition with a fade. The same axis brings in the room lobby and solo game. Step bars and the small waveform illustrations beneath card icons have been removed. Reduce Motion uses only a fade.

Room entry presents six code boxes over one native text input, preserving keyboard editing, OTP autofill and native paste. Its subtitle is “英字6桁のルームコードを入力してください。”. The keyboard is ASCII-capable and capitalizes every letter. Clipboard text availability is checked on entry, foregrounding and pasteboard changes; content is read when the user presses “クリップボードから貼付”. Paste accepts a bare code or a labeled invitation, normalizes lowercase/full-width letters, and rejects incomplete, numeric or overlong codes. Six letters trigger one join request, with input disabled during the request and inline correction/retry controls after failure. The lobby shares a labeled invitation through ShareLink; copying is available in the system share sheet. The separate copy and Apple Music connection buttons have been removed from the lobby.

The room’s top-left close button opens “ルームを退室しますか？” during both lobby and game phases. The confirmation panel scales in over a dimmed background, blocks interaction with the room, and offers cancel and leave actions. Duplicate leave requests are blocked while leaving. Reduce Motion uses a fade, and VoiceOver focus moves to the confirmation heading.

Review uses a native List with staggered card entrances, persistent segment counts, circular check/return controls, and native trailing swipe deletion. Artwork follows a shrinking arc into the destination segment, which pops on arrival. Learning changes persist at the start of the animation; switching tabs or enabling Reduce Motion cancels only the decoration. The native delete action animates the row removal and also remains available to VoiceOver.

Friends shows notification disclosures only when invitations or requests exist. An empty state guides players into the multiplayer flow; populated friend lists use the main area without surrounding empty cards. The account header combines avatar, name, and inline editing. Focus expands the name field ring. Apple Music and iCloud use grouped settings rows with status badges. A DisclosureGroup labeled “外部連携するとできること” sits below iCloud and explains playlist playback and iCloud data syncing when expanded. All new spatial motion respects Reduce Motion; oversized text wraps and retains scrolling.

## References
- Apple iOS UI Kit: https://www.sketch.com/s/04c24d8b-38fb-4afb-8836-36617e022f02/symbols
- Official Apple Music icon, unchanged SVG from Apple Music_Icon_2020 / Color / RGB / Large: https://apple.co/am-icon-2020
- https://marketing.services.apple/apple-music-identity-guidelines

## Verification
- Built the latest UI with no warnings or errors on iPhone 17 Pro / iOS 26.5. Verified the removed decorations, step bars, lobby copy/connection buttons, updated labels and exact code-entry subtitle.
- An isolated local QA room verified the confirmation in the lobby and during active listening. Cancel retained the room; confirming leave returned to the setup flow. Verified the external-connection accordion expands to both explanations and collapses again.
- Latest screenshots: [home](play-flow-home.jpg), [room selection](play-flow-room-selection.jpg), [mode](play-flow-mode.jpg), [playlist](play-flow-playlist.jpg), [code entry](play-flow-code.jpg), [host lobby](play-flow-host.jpg), [participant lobby](play-flow-participant.jpg), [lobby exit confirmation](room-exit-confirmation.jpg), [game exit confirmation](game-exit-confirmation.jpg), [connection benefits](account-connection-benefits.jpg).
- On 2026-10-03, XcodeBuildMCP built the new flow with no warnings or errors on iPhone 17 Pro / iOS 26.5. A separate `com.intro.IntoL.FlowQA` bundle used a temporary local server without modifying the repository environment or production app preferences.
- Verified solo mode → playlist connection screen, host creation in both quiz modes → lobby, valid six-letter entry → participant lobby without a Join button, and missing-room inline error/retry controls. Confirmed the uppercase software keyboard and that the six boxes remain visible above it.
- Before the separate lobby copy button was removed, verified that a labeled invitation on the clipboard is detected by the code screen and pressing the paste button parses it and joins the local room automatically.
- Room-code normalization and invitation validation, room-action recovery, and playlist preparation regression tests passed. Live Apple Music authorization/playback and real multi-device synchronization were not exercised.
- Earlier captures below describe older flows.
- On 2026-10-03, XcodeBuildMCP built and launched the updated app on iPhone 17 Pro, iOS 26.5, with no build warnings or errors. This earlier verification covered the previous home/mode crossfade; the new flow verification is recorded above.
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
