# SmartShot Runtime Acceptance: 2026-09-05

## Build and Scope

- Checkout: `/Users/kevinchen/Developer/SmartShot`, base commit `90caf29` with existing uncommitted changes.
- Source version: 0.2.2 (10).
- Existing installed application: 0.2.1 (7). It has not been replaced.
- Current test application: `/private/tmp/SmartShot-acceptance-20260905.X1sHp0/SafariFixedDerivedData/Build/Products/Release/SmartShot.app`.
- The initial permission-denial test used the preceding `SafariDerivedData` artifact. The `SafariFixedDerivedData` artifact contains the native JSON fix and was used for the subsequent import/OCR/permission observations.
- Final package with both the native JSON fix and browser quota fix: `/private/tmp/SmartShot-acceptance-20260905.X1sHp0/SafariQuotaDerivedData/Build/Products/Release/SmartShot.app`. Its build/signature checks passed, and the packaged `background.js` SHA-256 matches the checkout. This final package was not launched or installed.
- Signing: Xcode Sign to Run Locally, `CODE_SIGN_IDENTITY=-`; no Keychain identity is used by this development build.
- Build script: `Scripts/build_safari_development.sh`.
- Build passed. Universal arm64/x86_64 binaries, nested strict signatures, matching app/extension versions, sandbox/audio entitlements, and development get-task-allow checks passed.
- Original history and preferences were backed up under the private temporary acceptance directory before runtime testing.
- Controlled fixtures contain invented text, reserved example contact details, color blocks, and numbered rows only.

The first attempted persistent-certificate build failed during codesign with `errSecInternalComponent`. That build was not installed. The subsequent ad-hoc development build passed. This is a build-environment distinction, not an application runtime failure.

## Automated Baseline

Current source was tested earlier on 2026-09-05:

- Native: 199 passed, 0 failed, 0 skipped (195 XCTest and 4 Swift Testing cases).
- Browser extension: 109 passed, 0 failed, 0 skipped.
- JavaScript syntax, JSON, shell syntax, and `git diff --check` passed.
- Native result: `/private/tmp/SmartShot-status-20260905.8v04XG/SmartShot-unsandboxed.xcresult`.

After fixing the real JSON import failure below:

- Native: 202 passed, 0 failed, 0 skipped, confirmed with `xcresulttool get test-results summary`.
- Browser extension: 109 passed, 0 failed, 0 skipped.
- Result: `/private/tmp/SmartShot-acceptance-20260905.X1sHp0/native-after-fix.xcresult`.
- Hardware/environment: arm64 MacBook Air, macOS 26.6.2 (25G83).

After fixing the browser capture quota failure:

- Browser extension: 114 passed, 0 failed, 0 skipped, 0 cancelled.
- Log: `/private/tmp/SmartShot-acceptance-20260905.X1sHp0/browser-after-quota-fix.log`.
- Two quota regressions failed before the fix. New coverage includes multi-slice verification frames, concurrent windows, recovery after a rejected API call, tab changes while queued, and cancellation while queued.
- JavaScript syntax and `git diff --check` passed. The native source did not change after its 202-test pass.

## Runtime Record

| Case | State | Observation |
| --- | --- | --- |
| Development build and launch | Pass | Exact 0.2.2 (10) ad-hoc application launched; previous installed application was quit first. |
| Screen Recording denied | Pass | Capture showed "Allow Screen Recording access, then return and try again." Dismissing the alert returned to the normal interface. |
| Existing versus development permissions | Observed | The installed 0.2.1 application reported Screen Recording/Accessibility allowed. The new ad-hoc build reported both unavailable despite the existing SmartShot row being enabled in System Settings. |
| Screen Recording grant/recovery | Pass: permission and overlay | The user completed system authentication and explicitly authorized resetting the old SmartShot permissions. Adding the new app and toggling the old entry were insufficient. A targeted `tccutil reset ScreenCapture com.infinityf4p.SmartShot`, new request, grant, and relaunch made the current build report allowed. Capture then entered its overlay. Actual controlled output remains pending. |
| Accessibility grant/recovery | Pass: permission state | A targeted reset, new request, and system grant made the exact running development app report allowed. AX block selection still needs controlled runtime output. System Quit & Reopen briefly launched the installed 0.2.1 app; it was quit and the exact development process was verified before continuing. |
| Controlled browser page | Pass: setup only | The user explicitly authorized localhost access after an automatic approval rejection. `http://127.0.0.1:18765/?case=visible` loaded the expected English/Chinese text and boundary markers. No browser capture is claimed from this observation. |
| Chrome extension load/reload | User-confirmed reload; runtime action verified | After instructions to load/reload the checkout's `BrowserExtension` directory, the user confirmed completion. The toolbar action, selector, and subsequent controlled captures were observed. The browser tool still blocks `chrome://extensions`, so the loaded manifest was not independently inspected and no protected-page workaround was attempted. |
| Chrome visible capture/download | Pass: geometry and download | A toolbar invocation and fixture click produced `/Users/kevinchen/Downloads/127.0.0.1-x-post-2026-09-05T04-38-01-693Z.png`. It is 1240 x 902 pixels, matching the observed 620 x 451 CSS article at DPR 2, with complete top/bottom markers and all content. The automation pointer marker is visible in the output. This was a download, not native preview. |
| Chrome visible/native preview | Pass: controlled fixture | With only the native-host path temporarily changed to the fixed development helper, the toolbar action and article click produced an X post preview at 620 x 451 points in the exact running development app, plus a history PNG at 1240 x 902 pixels. The selector root disappeared and no page error remained. The original manifest was restored afterward. This is not an installed 0.2.1 or current-X compatibility claim. |
| Chrome long capture | Pass: geometry, native preview, and row completeness | After the confirmed reload, a real extension capture produced a 1240 x 5232 PNG and a 620 x 2616-point preview in the fixed development app. OCR found rows 001 through 048 exactly once, in order, with all 48 expected numeric values and both boundary markers. Page scroll returned to 0. No new quota error occurred in the resumed run. Automation pointer marks remain visible in the PNG; an earlier retry triggered the pixel-change guard. See the resumed-run notes below. |
| Real native host JSON input | Fixed; runtime pass | The original normal begin request returned `invalid_envelope`: JSON numeric 0/1 also satisfy Swift `is Bool`. The new serialized-input regression failed before the fix. The fixed packaged host accepted begin/index 0/end, and the exact current app displayed the 1400 x 1000 controlled PNG as 700 x 500 points. A separate index 1 chunk was rejected with `invalid_chunk`. This probe is separate from browser end-to-end acceptance. |
| Native overlay and Escape | Pass: two cycles | Capture displayed all four modes; Escape removed the overlay and returned Ready twice. The detected frontmost target remained the chat window, so no screenshot was confirmed. |
| Native Smart/Region/Long and shortcuts | Blocked by interaction control | Native coordinate click/drag repeatedly returned `noWindowsAvailable`, including after rebinding the app. AX buttons work, but bringing the controlled page to the physical foreground has not been verified. |
| Mixed Chinese/English OCR | Pass: controlled sample | Real Vision recognition returned all seven fixture lines in order, including Chinese, example email/phone, and a test card. |
| Long/tiled OCR | Pass: controlled sample | A 1400 x 6600 PNG was imported through nine real native chunks. OCR returned rows 001 through 084 exactly once, in order, with all 84 expected numeric values. This is OCR on a generated long image, not a browser or native long-capture pass. |
| Low-contrast and no-text OCR | Pass: controlled samples | Light-gray mixed-language text on white returned all seven expected lines. The color-block-only sample returned No Text. Rotated, over-limit, and broader accuracy cases remain pending. |
| Sensitive redaction and PNG Save | Pass with precision caveat | Sensitive (5) covered the email, phone, and card lines, plus two ordinary numeric lines (false positives). Save wrote `SS-20260905-redacted.png`, 1400 x 1000, and pixel inspection confirmed five opaque masks with intact borders/color blocks. |
| Private import/OCR history protection | Pass: history and index only | Private mode was enabled while OCR indexing remained on. Importing the nine-chunk long fixture and running OCR left all 30 history files (10 metadata entries at that moment) byte-for-byte unchanged: aggregate SHA-256 `53c2d2a5b74196b3338dbcbfdb9f46840755607aa861b7037f1ff75921c91223`. Automatic clipboard suppression was not independently observed. |
| History OCR search | Pass: match, reopen, and no-results states | Searching `ROW 048` left the captured long article as the result and reopened its 620 x 2616-point preview. Searching `SS-ACCEPTANCE-NO-MATCH-20260905` displayed No Results. Search was cleared afterward. |
| Pin | Pass: panel creation, scrolling, and close | Pin created a system floating window labeled Pinned screenshot containing the long image. It remained after the main window was closed. Scroll Down changed the vertical scrollbar from 0 to 0.2087198515769945, and the panel was closed. Cross-app/full-screen layering was not measured in this run. |
| Remaining editor/history/output | Pending | Magnifier placement failed at the automation layer before an annotation was placed. The full drag/edit, clipboard, JPEG Save, Quick Save, history deletion/retention, and Flatten GUI matrix is incomplete. JPEG selection was observed but no JPEG output is claimed. |
| Recording/audio/GIF | Not run | Permission approval was received, but controlled foreground/region interaction could not be established. No recording or microphone capture was started in this round. |
| Display matrix | One built-in display available | `system_profiler` reports Apple M4, one built-in Retina display, 1470 x 956 logical resolution and 2940 x 1912 rendered pixels. External/mixed-scale/cross-display cases were unavailable. Native edge geometry was not verified. |
| Chrome changing DOM content | Pass: rejection and restoration | A row changing its background every 100 ms triggered `Capture stopped because the selected block changed while scrolling.` at 2026-09-05T06:34:39.853Z. No new history image appeared. Scroll returned to 0, the selector disappeared, and only the fixture's original style element remained. This verifies DOM-mutation protection, not canvas/video detection. |
| Chrome nested-scroll article | Pass: explicit rejection and restoration | The final fixture placed the 2616-pixel-tall article inside a centered, 500-pixel-high scrolling ancestor. After the selector displayed `x-post`, Return produced `A block inside a nested scroll area cannot be scrolling-captured reliably.` at 2026-09-05T06:46:41.563Z. No article image appeared; page and nested scroll positions remained 0 and temporary styles were removed. Earlier outer-main selections are excluded from this result. |
| Safari | Not completed | Safari Settings status returned SFErrorDomain error 1; no current Safari capture is claimed. |

## Resumed Chrome Run

The resumed run reused the exact permission-granted `SafariFixedDerivedData` native app and its fixed JSON bridge, with the user-reloaded Chrome extension from the checkout. It did not launch the separate final Safari package. Only the Chrome native-host path was temporarily redirected to this helper.

The first resumed static capture stopped at 2026-09-05T06:26:51.847Z because selected pixels changed between verification frames. A later invocation using Chrome's native accessibility controls completed at 14:30 local time. The saved PNG contains repeated automation pointer marks near rows 003, 018, and 033; automation interference is a plausible explanation for the earlier rejection but was not isolated conclusively. The successful result proves complete geometry and native import with that artifact, not pointer-free output for every interaction path.

The nested fixture initially placed a scroll area inside the article, which did not exercise the scrolling-ancestor guard. It was corrected to wrap the article in a scrolling container. Accessibility actions without pointer movement then retained the selector's default outer `main`, producing three valid outer-main visible captures rather than selecting the article. Making the test article focusable alone did not resolve the final target selection. Centering the scrolling container made the page-center default resolve to `x-post`; the final Return invocation explicitly rejected that article as expected. These three outer-main images are diagnostic artifacts, not nested-article acceptance evidence.

The long PNG is `runtime-history/a89aada0-fb77-4e8e-aba9-d442f3d5835b.png`, SHA-256 `6c569d08b4d150b1068119d46f04c3672465d469ed6ab999680ff25cd2924536`. Its metadata retains the actual OCR index used to independently validate all 48 rows. The resumed run changed only the temporary fixture and documentation; production code and automated-test results remain the previously recorded 202 native and 114 browser passes.

## Fixes and Remaining Work

`BrowserCaptureImportStore` now distinguishes CFBoolean from numeric NSNumber values and uses checked exact integer conversion. Serialized-input regression tests and real packaged-host imports passed, including chunk indexes 0 and 1.

The browser background now serializes every `captureVisibleTab` call, including visible captures and long-capture verification frames, with at least 550 ms between calls. It rechecks the active tab/session after waiting and continues after a failed request. The former per-slice interval did not pace the verification calls. Chrome documents a two-call-per-second limit in its [Tabs API reference](https://developer.chrome.com/docs/extensions/reference/api/tabs#property-MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND). Existing capture duration/size limits remain in force.

The user completed the requested manual extension reload, and the controlled Chrome long capture plus dynamic/nested rejection cases have now been exercised. No protected-page workaround was used. Earlier native coordinate actions repeatedly returned `noWindowsAvailable`; attempting Dock-based activation also timed out. Native screenshot geometry, complete editing, recording/audio, Safari, and the broader display/browser matrix remain pending.

## Cleanup

- Private mode is back off and output format is back to PNG; microphone/system-audio capture remained off.
- The Chrome native-host manifest was restored byte-for-byte to its original `/Applications/SmartShot.app` helper path.
- The initial three generated history captures and the resumed run's four captures, including metadata/thumbnails, were moved to the temporary `runtime-history` evidence directory. The live history contains exactly the original 21 files belonging to seven entries, all byte-for-byte unchanged.
- Search was cleared, the pinned panel was closed, the temporary application was quit, and the fixture server was stopped. No SmartShot process remained. The browser fixture tab was retained.
- The launched temporary app/extension registrations were removed again after the resumed run. Plugin inventory after the initial cleanup contained only the original installed 0.2.1 extension.
- The granted TCC permissions belong to the tested development signature. The user explicitly approved resetting old SmartShot grants; another signed artifact can require its own grant. No Keychain credential was unlocked or installed during the successful development builds.

## Evidence Location

Runtime logs, controlled fixtures, and local-only backups are under `/private/tmp/SmartShot-acceptance-20260905.X1sHp0`.

The visible native Chrome preview artifact is `runtime-history/045d62e2-6516-496f-80aa-23685910af7d.png`; the successful browser long capture is `runtime-history/a89aada0-fb77-4e8e-aba9-d442f3d5835b.png`. The manually saved masked image is `SS-20260905-redacted.png`. The final package build log is `safari-quota-build.log`.

For another local run, start the fixture with `node /private/tmp/SmartShot-acceptance-20260905.X1sHp0/site/server.mjs` and re-establish the recorded development-host path before testing native import. Reload the repo's unpacked Chrome extension after any further extension changes. The persistent installed helper was intentionally restored and does not contain these uninstalled fixes.

Do not treat setup, a permission toggle, a protocol-only probe, or an automated test as a passed browser or native screenshot workflow. Each runtime result applies only to the exact recorded artifact and scenario.
