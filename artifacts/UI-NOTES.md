# UI refresh — 2026-10-11

Home, room selection, and quiz mode selection use matching white action cards. Only the leading icons carry the Studio red; chevrons, back actions, breadcrumb text, and player names use neutral text colors. Red remains on primary actions and selected tabs. Repeated SOLO / INTRO / HOST / JOIN overlines were removed. Player metadata is Japanese “2〜4人”; SABITRO remains the brand label. Short Japanese descriptions fit comfortably at the default text size. Sabitro uses music.note.list, distinct from the Play tab's waveform.

Shared card tokens define action-card and grouped-information radii, padding, and border width. Home choices, settings groups, volume cards, and friend notifications share the same surface and border system. Requests use SF Symbols, a primary approval button, and a text rejection control with at least a 44pt tap target. Friends uses pull-to-refresh and an empty-state explanation connecting multiplayer to friend requests. Invitations show the mode and current occupancy; full-room invitations are disabled with a reason. Older servers without occupancy data still decode and show the generic 2〜4人 range.

The lobby header contains close and volume controls. “対戦待機室” appears once, with waiting/full state below it. The display code is a monospaced capsule, distinct from six input boxes. Copy and Share are matching secondary buttons. The local player has an outline and “あなた” label; the host has a crown and text role label. A full lobby explains why invitations are disabled. Guests have a fixed waiting footer; Reduce Motion uses a static hourglass. At accessibility text sizes, the player grid switches to two columns and Copy/Share stack vertically. The settings card summarizes playlist / questions / lives; configuration and read-only rule details remain accessible after expanding it. The footer occupies a safe-area inset and a small fade signals more scroll content.

Read-only rule details now use a plain vertical list instead of a summary card. Each rule has its own label/value row, grouped under 出題 and 得点とライフ. Zero target score is shown as なし, zero lives as 無制限, and endless mode removes the answer-slot limit. The host's rule editor is unchanged. The follow-up built with no warnings or errors and was checked in the signed com.intro.IntoL app on iPhone 17 Pro / iOS 26.5: opening details, dismissing with 完了, all nine rows at the default text size, and scrolling to the final row at the largest system text size. The simulator's original large text-size setting was restored afterward. The new detail screenshot uses the current status-bar time.

Start availability is shared between the lobby and start action. It requires two players, enough playlist songs for the question count, Apple Music authorization/subscription where applicable, and all players' asset readiness for already-prepared rooms. The action rechecks eligibility after lobby synchronization and after song preparation. Current app room creation sends minimumPlayers: 2; the server persists it and rejects starts if a participant leaves before the request arrives. Legacy room/client behavior is retained. Matching can still find fewer playable unique songs than the library count; the existing preparation error explains that shortage.

Exit confirmations emphasize Cancel and use an outlined destructive Leave button. The explanation follows the implementation: the host transfers automatically to a remaining participant, the final departure closes the room, and a player leaving during a game is removed from its final standings. Per-question statistics already saved remain recorded, so the dialog does not claim all score records are discarded. Account uses a neutral name with an adjacent edit icon, attention-colored inactive connection badges, “接続する” for Apple Music, plain iCloud/local-storage wording, and “曲の音量”.

## Current screenshots

All 16 existing JPEGs were refreshed and seven verification images were added. Captures use an isolated com.intro.IntoL.UIReview bundle on iPhone 17 Pro / iOS 26.5, v5.1.1, 368 × 800 JPEG, with the status bar fixed to 9:41. Offline Debug fixtures use a local-only service URL and skip automatic friend refresh. Normal app data and repository environment settings were preserved. Account fixtures show the iCloud-not-connected message without exercising live iCloud. The original 3-song / 6-question fixture mismatch is fixed to 3 questions; explicit shortage fixtures retain 6 questions.

| Screen | Screenshot |
| --- | --- |
| Home | [home.jpg](home.jpg), [play-flow-home.jpg](play-flow-home.jpg) |
| Room selection | [play-flow-room-selection.jpg](play-flow-room-selection.jpg) |
| Mode selection | [play-flow-mode.jpg](play-flow-mode.jpg) |
| Solo playlist connection | [play-flow-playlist.jpg](play-flow-playlist.jpg), [sources.jpg](sources.jpg) |
| Input code boxes, keyboard hidden | [play-flow-code.jpg](play-flow-code.jpg) |
| Host, one participant / disabled start | [play-flow-host.jpg](play-flow-host.jpg) |
| Guest, full lobby / waiting footer | [play-flow-participant.jpg](play-flow-participant.jpg) |
| Guest, read-only rule list | [lobby-guest-rule-details.jpg](lobby-guest-rule-details.jpg) |
| Lobby exit / host transfer explanation | [room-exit-confirmation.jpg](room-exit-confirmation.jpg) |
| Game exit | [game-exit-confirmation.jpg](game-exit-confirmation.jpg) |
| Friends / requests / invitations | [friends.jpg](friends.jpg), [friend-request.jpg](friend-request.jpg), [invite.jpg](invite.jpg) |
| Account / benefits | [account.jpg](account.jpg), [account-connection-benefits.jpg](account-connection-benefits.jpg) |
| Two participants / enabled start | [lobby-ready.jpg](lobby-ready.jpg) |
| Song shortage, host / guest | [lobby-host-song-shortage.jpg](lobby-host-song-shortage.jpg), [lobby-song-shortage.jpg](lobby-song-shortage.jpg) |
| Dark lobby | [lobby-guest-dark.jpg](lobby-guest-dark.jpg) |
| Largest Dynamic Type, code / players / settings | [lobby-large-text.jpg](lobby-large-text.jpg), [lobby-large-text-players.jpg](lobby-large-text-players.jpg), [lobby-large-text-settings.jpg](lobby-large-text-settings.jpg) |

The app built with no warnings or errors. Runtime checks covered neutral choice cards, copy feedback, Cancel retaining the room, full-room invitation state, enabled/disabled start, song shortage, the guest footer, connection benefits, and scrolling to players and settings at the largest Dynamic Type size. All images were visually inspected. Apple Music playback, actual subscription authorization, live iCloud synchronization, and multi-device timing were not exercised.

Validation passed: server node --test (74 tests), room-lobby readiness, room-action recovery, playlist preparation, game recovery, CloudProfile, and room-code Swift tests. The full server suite was rerun with local socket permissions after the sandbox prevented a localhost WebSocket listener from opening. ui-demo.mp4 remains the historical 2026-09-28 recording. Server occupancy metadata and enforcement of the two-player minimum for new app rooms require redeploying the updated server.

## Room rule help (2026-10-11)

All nine room rules have a small, muted circled question mark beside the label. It opens a scale-and-fade explanation card; Reduce Motion uses a fade. Editing and read-only details share the descriptions. Help remains available when endless mode disables answer-slot editing. Long explanations scroll at the largest Dynamic Type size, with the close button kept visible; the underlying settings are hidden from accessibility while help is open.

Victory target and lives display “制限なし” for zero in their original value positions and wheel options. Lobby summaries and guest details use the same wording. Zero bonuses and penalties remain numeric. Endless mode displays “制限なし” for its disabled answer-slot value.

XcodeBuildMCP built the app with no warnings or errors on iPhone 17 Pro / iOS 26.5. Runtime verification covered opening and closing all nine explanations, unchanged setting values, the victory-target wheel, endless-mode help, dark details, and scrolling long explanations at accessibility5. Direct fixtures are `rules-host-unlimited`, `rules-host-unlimited-large-text`, and `rules-guest-unlimited-dark`.

Screenshots: [rule settings](room-rules-unlimited.jpg), [explanation](room-rule-explanation.jpg), [dark explanation](room-rule-explanation-dark.jpg), [largest text](room-rule-explanation-large-text.jpg).

## References
- Apple iOS UI Kit: https://www.sketch.com/s/04c24d8b-38fb-4afb-8836-36617e022f02/symbols
- Official Apple Music icon, unchanged SVG from Apple Music_Icon_2020 / Color / RGB / Large: https://apple.co/am-icon-2020
- https://marketing.services.apple/apple-music-identity-guidelines

## Historical verification
- Built the latest UI with no warnings or errors on iPhone 17 Pro / iOS 26.5. Verified the removed decorations, step bars, lobby copy/connection buttons, updated labels and exact code-entry subtitle.
- An isolated local QA room verified the confirmation in the lobby and during active listening. Cancel retained the room; confirming leave returned to the setup flow. Verified the external-connection accordion expands to both explanations and collapses again.
- Screenshot filenames from that verification are retained and have now been refreshed; see the current screenshot list above.
- On 2026-10-03, XcodeBuildMCP built the new flow with no warnings or errors on iPhone 17 Pro / iOS 26.5. A separate `com.intro.IntoL.FlowQA` bundle used a temporary local server without modifying the repository environment or production app preferences.
- Verified solo mode → playlist connection screen, host creation in both quiz modes → lobby, valid six-letter entry → participant lobby without a Join button, and missing-room inline error/retry controls. Confirmed the uppercase software keyboard and that the six boxes remain visible above it.
- Before the separate lobby copy button was removed, verified that a labeled invitation on the clipboard is detected by the code screen and pressing the paste button parses it and joins the local room automatically.
- Room-code normalization and invitation validation, room-action recovery, and playlist preparation regression tests passed. Live Apple Music authorization/playback and real multi-device synchronization were not exercised.
- Earlier captures below describe older flows.
- On 2026-10-03, XcodeBuildMCP built and launched the updated app on iPhone 17 Pro, iOS 26.5, with no build warnings or errors. This earlier verification covered the previous home/mode crossfade; the new flow verification is recorded above.
- A separate local QA bundle with synthetic demo reviews, friends, requests, and invitations verified learning in both directions, updated counts, the flying artwork, the native accessibility delete action and row removal, compact notification disclosures, populated lists, and the room-creation route. Existing review data in the normal app was preserved.
- Checked 375pt-wide content, the largest Dynamic Type size, the Reduce Motion code paths, and inline name focus/commit. Live Apple Music playback, iCloud account synchronization, and multi-device multiplayer were outside this UI verification.
- The video below documents the 2026-09-28 layout. The JPEG screenshots have since been regenerated on 2026-10-07.
- On 2026-09-28, XcodeBuildMCP built and launched the latest app on iPhone 16 Pro, iOS 18.6.
- [ui-demo.mp4](ui-demo.mp4) shows a room invitation arriving in the Friends tab, joining without entering a room code, the in-room Friends sheet and its Close button, solo practice, review, and account settings. Idle waits were removed from the recording.
- [friends.jpg](friends.jpg), [friend-request.jpg](friend-request.jpg), and [invite.jpg](invite.jpg) show the empty Friends tab, an incoming friend request, and an incoming room invitation.
- The friend request, approval, and invitation were exercised against the latest server running locally for the demo. The simulator app bundle used a local server URL; the repository's `.env` was not changed.
- Default text size: home, source selection, account settings and solo answer controls fit without scrolling.
- Apple Music subscription playback and multiplayer over multiple devices were not exercised.
- Startup showed an existing “Privacy acknowledgement required” service alert; dismissed for the local demo.
