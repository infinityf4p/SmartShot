# SmartShot Handoff

## Snapshot

The capability table below records the 2026-08-24 snapshot. The full automated gates were rerun on **2026-09-14**: **205/205 native** and **114/114 browser** tests passed with no failures or skips; see the [test plan](TEST_PLAN.md). The README's ad-hoc Release build and strict nested signature checks also passed without a Keychain signing certificate. No application was installed or launched for this publication check.

The [2026-09-06 acceptance record](ACCEPTANCE_2026-09-06.md) adds PNG/JPEG Quick Save, Number/Text, Undo/Redo, Flatten replacement, and video-only recording/playback. The resumed run verifies editor refresh, drag-based cropping, history reopen, rectangle move/delete, 59.3-second system-audio recording with 59 detected test tones, a 30.00-second GUI GIF export, recording cancellation, and Region output scaling. Actual microphone recording, A/V sync, controlled native capture boundaries, clipboard pixels, and Safari capture remain pending.

The [2026-09-05 acceptance record](ACCEPTANCE_2026-09-05.md) contains the native JSON/browser quota fixes, controlled Chrome visible/long native previews, dynamic/nested rejection, and OCR/redaction/private-history/search/Pin checks. The Chrome reload and long-capture retest are complete. The installed 0.2.1 app has not been replaced; temporary packages use Sign to Run Locally without a Keychain identity.

Keep these evidence classes separate:

- **Implemented**: code and a user-facing entry point exist.
- **Automated coverage**: checked-in deterministic tests cover the named logic.
- **GUI verified**: a recorded signed-app or privileged runtime scenario passed.
- **GUI pending**: the real permission, installation, browser, display, or interaction path has not been recorded.
- **Foundation only**: reusable code exists without a complete user workflow. No current capability in the table should be promoted from this label without an entry point and acceptance boundary.

A successful build, a green unit test, a configured native-host manifest, and a real end-to-end capture are different facts.

## Current Capability Boundary

| Capability | State | Evidence and limit |
| --- | --- | --- |
| Smart, Region, and nested selection | Implemented | Signed Smart and Region captures plus four-mode overlay Escape cancellation were recorded on 2026-08-23. Screen Recording is required; AX blocks need Accessibility. Global-hotkey/full-screen and broader display cases remain pending. |
| Manual Long | Implemented | A controlled three-fragment TextEdit workflow was recorded on 2026-08-23. One fixed single-display region, user scrolls downward; 24 fragments, 5 minutes, 20,000 logical points, 16,384 px per axis, 32 million pixels. |
| Automatic App Scroll (Experimental) | Implemented | A controlled static `NSScrollView` success and forced-timeout restoration were recorded on 2026-08-15. Static single-display AX scroll area with a writable vertical scrollbar only; 24 fragments, 75 seconds, 20,000 logical points, 16,384 px per axis, 32 million pixels. |
| Editor and output | Implemented | Pixel tests cover all current raster/vector effects. An earlier GUI run covered the basic subset; freehand, ellipse, blur, opaque redaction, spotlight, magnifier, select/move/delete, and OCR-assisted redaction still need GUI acceptance. PNG/JPEG, Copy, Pin, Save, Quick Save, and Flatten exist. |
| OCR and sensitive-text assistance | Implemented | Vision tiling/geometry, reading order, deduplication, cancellation, and validators have tests. Real OCR accuracy, language behavior, UI, and redaction placement remain GUI pending. |
| History | Implemented | Local PNG/thumbnail/metadata persistence, retention, replacement, search, load, delete, and clear have store coverage. UI exposes search/list/open/delete/clear and 10/25/50/100/250 retention. OCR indexing is a separate opt-in and is forbidden for Private captures. |
| Private capture mode | Implemented | A signed capture left the existing six-item history unchanged. Policy tests also cover automatic clipboard suppression. Private mode does not block explicit Copy, Pin, Save, Quick Save, or browser fallback downloads. |
| URL scheme and CLI | Implemented | The installed `capture`, `quick-save`, `show`, help, and invalid-input paths were exercised. Capture and Quick Save did not activate SmartShot in the controlled TextEdit run; another app's full-screen Space remains pending. Show activates SmartShot. CLI is embedded, fire-and-forget, and not installed on `PATH`. |
| Chromium/Safari native preview import | Implemented | Two-phase bridge staging then app validation/preview; final acceptance waits for the app. Long slices use heuristic two-frame pixel checks. One outstanding import is allowed, and background-owned fallback survives page teardown when `downloads` is available. Real signed extension installation, current X, site permissions, zoom, and preview import remain GUI pending. |
| Screen recording | Implemented; partially GUI verified | A 22.18-second 994 x 622 H.264 region recording, in-app preview, Save As, and 333-frame GIF export were recorded on 2026-08-23. The run intentionally had system audio, microphone, and pointer off; display capture, audio/A-V sync, sustained operation, permissions, and failure cases remain pending. |

## Build and Install

Requirements: macOS 14+, a recent compatible Xcode, XcodeGen, and Node.js.

```sh
xcodegen generate
xcodebuild -project SmartShot.xcodeproj \
  -scheme SmartShot \
  -configuration Debug \
  -derivedDataPath DerivedData \
  test CODE_SIGNING_ALLOWED=NO

cd BrowserExtension
npm test
```

For real native permission, URL-scheme, CLI, and Chromium checks, build with the configured local signing identity or intentionally configured development-team signing, then install the complete bundle as `/Applications/SmartShot.app`. Safari development is a separate signing case described below. The post-build phase embeds:

- `Contents/Helpers/SmartShotNativeHost`
- `Contents/Helpers/smartshot`
- `Contents/PlugIns/SmartShot Safari Extension.appex`

An older app already present in `/Applications` is not evidence that these helpers are current. Inspect the installed bundle before GUI testing.

The current local release artifact is self-signed, not Developer ID signed or notarized. Gatekeeper can require explicit Finder **Open** or **Privacy & Security** approval after download. Do not represent a passing build, local launch, or existing TCC permission as clean-machine distribution acceptance.

The 2026-08-24 installed Release artifact was built universal, passed strict deep signature verification, matched the staged app byte-for-byte, launched successfully, and remained alive through repeated Safari status refreshes. That verifies this installed artifact and the status callback fix only; it does not pass Gatekeeper, browser, or capture acceptance.

## Browser Setup

Follow [BrowserExtension/README.md](../BrowserExtension/README.md).

Chromium support currently covers Google Chrome, Chromium, Microsoft Edge, and Brave. SmartShot Settings writes a per-browser `com.infinityf4p.smartshot.json` native-host manifest only when the complete app is at `/Applications/SmartShot.app`. **Connected** means those manifests match the expected helper and pinned extension origin; it does not prove that the unpacked extension is loaded, has site access, or completed a capture.

The unpacked extension inside the installed app is `/Applications/SmartShot.app/Contents/PlugIns/SmartShot Safari Extension.appex/Contents/Resources`. Chromium's Developer mode and **Load unpacked** controls are protected, user-controlled browser UI. SmartShot can configure the native host and reveal packaged files, but it does not and should not claim to complete extension installation automatically.

Both browsers first validate and stage a completed browser-produced PNG through strict `begin -> chunk -> end` messages, then open SmartShot and wait for app validation and preview publication before returning the accepted end acknowledgement. `AppModel` allows one outstanding browser import. Native failure or overlap first uses the extension background's `downloads` API so fallback does not depend on the content page; a live content page remains a second fallback. The extension does not inspect download history.

Chromium holds the staged image in the bounded Application Support store. Safari moves it through request-scoped named pasteboards because the sandboxed extension and containing app do not share that private directory. Normal paths validate and clean up the boards, but the channel has no cryptographic source authentication against another process running as the same macOS user, and an extension crash after publication can leave bounded request residue. Treat both as accepted P2 boundaries of this local self-signed release.

The persistent `/Applications` artifact has a custom local self-signed identity. That identity is sufficient for native testing but Safari does not accept its embedded WebExtension merely because **Allow unsigned extensions** is enabled. Use Apple development signing, or build the complete container and extension with Xcode's **Sign to Run Locally**, launch that exact build, then enable **Settings > Developer > Allow unsigned extensions** and the extension. Safari resets the override whenever it quits. Rebuild to a fresh path/version instead of replacing registered resources in place. Do not require this development path for a future Apple-signed distribution build.

Do not describe the browser path as DOM-to-AppKit coordinate mapping. The current design captures/crops/stitches in the browser and imports the completed PNG.

## Automation

Public local commands are:

```text
smartshot://capture?mode=smart
smartshot://capture?mode=region
smartshot://capture?mode=long
smartshot://capture?mode=app-scroll
smartshot://quick-save
smartshot://show
```

The bundled launcher accepts `capture [--mode smart|region|long|app-scroll]`, `quick-save`, `show`, and `--help`. It calls LaunchServices and exits; it does not wait for capture completion or report an output file. Capture and Quick Save request non-activating delivery, which passed in a controlled TextEdit run; another app's full-screen Space remains pending. Show activates SmartShot. `smartshot://import` is internal to the validated browser bridge.

## Storage and Privacy

- History is enabled by default under `~/Library/Application Support/SmartShot/History` and stores a PNG, JPEG thumbnail, and JSON metadata for each retained item. The UI supports search, open, delete, confirmed clear, and retention limits.
- Search always covers labels and saved-file basenames. OCR text joins the local index only after the separate off-by-default opt-in and an OCR run; Private captures never persist OCR index text.
- Private mode suppresses only automatic history and automatic copy. The latest preview remains in memory and explicit output actions still work.
- Quick Save writes atomically to the configured folder, initially `~/Pictures/SmartShot`; Save uses a panel. Output can be PNG or JPEG.
- Vision OCR and sensitive-pattern detection run locally. Detected classes currently include email, phone, Luhn-valid payment-card numbers, and checksum/date-valid Chinese national IDs.
- Opaque redaction is the privacy tool. Blur and mosaic are visual effects and must not be represented as irreversible sanitization.
- Browser import includes PNG bytes, safe kind/filename, logical dimensions, and an HTTP(S) origin. It excludes post text, author, title, selector, HTML, credentials, path, query, fragment, cookies, and browsing history.
- Screen recordings are local H.264/AAC MP4 files in the Quick Save folder, outside screenshot history and Private capture policy. Microphone is off by default and separately permissioned. GIF export is silent and bounded to 30 seconds, 15 fps, 1,280 px, and 450 frames.
- There is no analytics, upload endpoint, account, cloud sharing, or synchronization.

## Long Capture Claims

Keep the three contracts distinct:

1. **Manual Long** captures a fixed rectangle while the user scrolls. It does not restore the user's scroll position or know the semantic end of a post.
2. **Automatic App Scroll (Experimental)** drives one writable AX scrollbar, validates static geometry/pixels, and attempts exact restoration after success, failure, or cancellation.
3. **Browser whole-block capture** selects one DOM element, uses a visible fast path or bounded page scrolling, restores page state, and imports or downloads one PNG.

None promises dynamic/infinite feeds, virtualized lists, nested scrolling, cross-display composition, horizontal scrolling, or automatic X thread/multi-post capture.

## Recorded Evidence

- The native Swift test gate passed **199/199** on 2026-08-24.
- The BrowserExtension Node gate passed **93/93** on 2026-08-24.
- A fresh universal **0.2.1 (build 7)** Release app on 2026-08-24 passed strict deep signature verification, was installed at `/Applications/SmartShot.app`, and launched from that exact path. The browser manifest version is **0.2.1**.
- Stale temporary Safari-extension registrations were removed again after build 7, leaving exactly one registration for the fresh `Sign to Run Locally` Clean7 development artifact. This records environment repair and registration state, not extension enablement or capture success.
- An earlier `Sign to Run Locally` SmartShot Web Selector 0.2.1 development build was listed and enabled in Safari 26.5.2 and had its toolbar item added. A later physical toolbar attempt did not establish selector activation. Clean7 is currently registered, but selector injection, Website Access recovery, capture, native preview, and fallback remain unverified.
- The post-capture editor basic subset was exercised from a signed Debug fixture on 2026-08-19: tool switching, text/counter placement, undo/redo, 150% zoom, and Pin.
- Controlled automatic AX scrolling on 2026-08-15 produced a 2,688 x 8,724 PNG containing rows 001 through 240 and restored the exact original scrollbar value; a forced timeout restored the same value.
- The BrowserExtension Node suite covers X/generic DOM fixtures, restoration guards, bounded geometry, strict import ACKs, and fallback behavior.
- The native test targets contain coverage for import storage, Chromium manifest installation, URL/CLI parsing, history, private policy, output encoding, OCR support logic, editor rendering, shortcut registration, and long-capture algorithms.
- Recording tests cover source/size planning, state/routing, H.264/AAC configuration, cleanup, and a synthetic offline MP4-to-GIF export path.
- The installed Release app recorded Smart and Region captures, a three-fragment Manual Long result, overlay Escape cancellation, Pin, Quick Save, and Private history suppression on 2026-08-23.
- The installed CLI exercised capture modes without activating SmartShot, Quick Save output, activating Show, help, and invalid input on 2026-08-23.
- A live region recording on 2026-08-23 produced a 22.18-second 994 x 622 H.264 MP4, remained in the same app process for preview, completed Save As, and exported a 994 x 622 333-frame GIF. Audio and microphone were disabled for this narrow run.

Do not turn checked-in coverage into a passing-current-suite claim unless the final `xcodebuild test` result for the current checkout is recorded.

## Remaining Acceptance Work

- Clean-machine signing/Gatekeeper verification beyond the installed self-signed bundle.
- Gatekeeper behavior for the current self-signed artifact on a clean or newly downloaded copy; Developer ID signing/notarization is not complete.
- Screen Recording and Accessibility denial/grant/revoke recovery.
- Frontmost-app shortcut delivery, full-screen Spaces, mixed displays/scales, negative origins, and overlay teardown.
- Complete editor/OCR/history search/retention/restart GUI workflow beyond the recorded subset and Private history check.
- Public controlled Chrome, Safari, and X fast/long capture with native preview and fallback evidence, including the `downloads` permission prompt, page teardown, Safari API degradation, toolbar diagnostics, and dynamic-media false-positive/false-negative checks.
- Explicitly load/reload the unpacked extension in Chromium. Safari development enablement is recorded, but a physical action invocation, Website Access denial/recovery, controlled capture, and native import remain pending.
- Safari named-pasteboard cleanup after forced timeout/crash and same-user interference behavior, without treating the current P2 boundary as authenticated IPC.
- Remaining URL/CLI collision, failure, active-operation, and full-screen-hotkey cases.
- Recording still needs current-display, system audio, microphone, A/V sync, Cancel, display changes, sustained duration, and failure-cleanup checks.

## Claim Rules

- Say **implemented with automated coverage and a narrow signed GUI subset** for OCR, history, private mode, and automation until their complete matrices are recorded. Browser import remains GUI pending until a real extension capture reaches native preview.
- Keep **Experimental** in the name of Automatic App Scroll.
- Say **implemented with focused automated coverage and one narrow live region/video-only check** for screen recording until the recording matrix passes.
- Never claim general-purpose long screenshots, automatic X threads, guaranteed OCR/sensitive detection, object removal, translation, cloud sharing, or sync.
- Never publish private X timelines, screenshot pixels, cookies, page HTML, full AX values, or sensitive URLs as test evidence.

## Key Files

- `README.md`: public status and use.
- `Docs/MVP_REQUIREMENTS.md`: current supported scope and exclusions.
- `Docs/ARCHITECTURE.md`: implementation boundaries and data flow.
- `Docs/TEST_PLAN.md`: promotion gates and test-record template.
- `Docs/ROADMAP.md`: remaining product work.
- `BrowserExtension/README.md`: browser install, protocol, limits, and fallback.
