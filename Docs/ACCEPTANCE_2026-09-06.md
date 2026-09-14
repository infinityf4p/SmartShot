# SmartShot Runtime Acceptance: 2026-09-06

## Build and Scope

This continues the [2026-09-05 acceptance run](ACCEPTANCE_2026-09-05.md). Times below are Asia/Shanghai. The source remains 0.2.2 (10), based on `90caf29` with existing local changes. The installed `/Applications/SmartShot.app` remains 0.2.1 (7).

Evidence root: `/private/tmp/SmartShot-acceptance-20260905.X1sHp0`.

- Editor, PNG/JPEG, Flatten, display recording, playback, and initial GIF observations used `SafariFixedDerivedData/Build/Products/Release/SmartShot.app`, the previous permission-granted build.
- `EditorGIFFixedDerivedData/Build/Products/Release/SmartShot.app` contains the editor-refresh and GIF-timing fixes, plus the previous native JSON and browser quota fixes. Its universal build and strict nested signature checks passed. The resumed run beginning at 11:27 verified editor refresh, drag-based cropping, system-audio recording, GIF export, and recording cancellation on this artifact.
- Builds use Sign to Run Locally (`CODE_SIGN_IDENTITY=-`), without Keychain access. No development app was copied to `/Applications`.
- Protocol imports, offline export verification, and GUI acceptance are separate evidence categories. The recorded desktop video is private local evidence, not a controlled-fixture capture or a publishable sample.

## Automated Results

- Final native suite: **205 passed, 0 failed, 0 skipped**, confirmed with `xcresulttool get test-results summary` on `editor-gif-full.xcresult`.
- Browser suite: **114 passed, 0 skipped** in the September 5 run. Browser source did not change in this continuation, so that suite was not rerun.
- Before the GIF change, the editor-only full suite passed **202/202, 0 skipped** in `editor-followup-clean.xcresult`. An earlier run skipped one shortcut-conflict case because the running test app owned its fallback key; quitting that app resolved the conflict.
- The new encoded-GIF regression failed before the fix: a 1.00-second export lasted 1.05 seconds, and a 0.73-second export lasted 0.77 seconds (`gif-timing-red.xcresult`). It passed after the fix.
- New timing tests cover every supported frame rate (1 through 15), partial final frames, very short clips, centisecond granularity, and bounded cumulative timing. The integration test decodes every exported frame and measures the delays stored in the actual GIF.
- The first boundary-test run required a floating-point epsilon around the 5 ms quantization limit. The final full run above includes that assertion correction.

Native command:

```sh
xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/SmartShot-acceptance-20260905.X1sHp0/EditorTestDerivedData \
  -resultBundlePath /private/tmp/SmartShot-acceptance-20260905.X1sHp0/editor-gif-full.xcresult \
  test CODE_SIGNING_ALLOWED=NO
```

## Early Runtime Results (00:xx)

| Case | Result | Evidence and limit |
| --- | --- | --- |
| Number, Undo, Redo | Pass on previous development build | An accessibility click placed a red number 1 in the controlled PNG. Undo removed it and enabled Redo; Redo restored it. Coordinate dragging still failed with `noWindowsAvailable`. |
| Quick Save PNG | Pass | `SmartShot 2026-09-06 00.41.27.png`, 1400 x 1000, contains the number and intact fixture borders, text, and color blocks. Its SHA-256 is `0c772651591d7c3e6236a44472cbd4dd42cd844d0e9aef92a9d6cfbccfa6ab26`. |
| Flatten | Pass: replacement on owned test item | Flatten reported success and disabled Undo/reset. History item `a2229f10-31a1-4587-ad82-f87d477bac4b` became byte-identical to the number PNG above. The original PNG was preserved separately as `editor-history-before-flatten.png`. |
| Text and JPEG Quick Save | Pass | The Text tool placed `SS EDIT TEXT 20260906`. PNG `00.46.51` and JPEG `00.48.16` were written at 1400 x 1000; the actual JPEG was visually inspected. Text and number overlap because both were placed by a center-point accessibility click; free positioning is not claimed. Output format was restored to PNG. |
| PNG Save As | Incomplete | The save dialog accepted navigation and a filename but kept Save disabled. It was cancelled and no `SS-20260906-number.png` was created. Earlier PNG Save and this run's GIF Save succeeded, so this alone does not establish an application save failure. |
| Current-display recording | Pass: short video-only output | Start/Stop produced `SmartShot Recording 2026-09-06 00.54.15.mp4`: 14.6 seconds, 1918 x 1248, one H.264 video track, no audio track, nominal frame rate about 28.08 with a 30 fps setting. Two sampled frames decoded and contained nonblank, changing pixels. The recording includes the physical desktop and a macOS screen-access prompt, not the controlled fixture. |
| In-app playback | Pass on previous development build | Playback started, the timeline advanced, and playback finished at 14.6 seconds. This does not verify audio, A/V sync, or a sustained recording. |
| GIF Save | Pass with timing defect, subsequently fixed | The GUI wrote a 1280 x 832 GIF with 219 decodable frames. Its stored delays totaled 15.33 seconds versus the source's 14.60 seconds. The corrected production exporter reprocessed that same MP4 into `video-only-timing-fixed.gif`: 219 decodable frames, 1280 x 832, **14.60 seconds**. This corrected re-export used the production service through a local helper, not the new app's GUI. |
| New build native import | Pass: protocol and stored image | The packaged helper acknowledged begin/chunk/end for request `67eef85f-fd30-4ac5-8620-c60d4033f162`. The new app wrote controlled history item `e04bdb7d-5771-4c35-a47e-6b9cc7521745`. Window pixels and post-fix editor interaction could not be observed. |
| Microphone | Pending | Allow was invoked, but SmartShot continued to report Not allowed and no matching microphone row appeared in System Settings. No microphone recording was started. System-audio and microphone controls remained off. |
| Safari and native drag workflows | Pending | No new Safari capture, drag-based editor action, or native region output is claimed. |

## Fixes and Remaining Work

`AppModel` now forwards the active `CaptureEditorModel.objectWillChange` publisher and replaces the subscription when the editor changes. Previously, Flatten did not appear after an annotation until another parent-model action, such as Quick Save, refreshed the view. The 11:27 resumed run verified immediate button appearance/removal, editor replacement, and crop-size refresh on the new build. The existing test target does not directly exercise `AppModel`.

`GIFFramePlan` now rounds cumulative frame boundaries and supplies a separate delay for each frame. GIF stores delay in hundredths of a second, as defined by the [GIF89a specification](https://www.w3.org/Graphics/GIF/spec-gif89a.txt). Rounding each 1/15-second delay independently caused the observed five-percent drift. Final fragments shorter than 20 ms are folded into the preceding frame; a clip shorter than 20 ms uses one 20 ms frame. This avoids the tiny-delay expansion used by decoders such as [WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/image-decoders/ScalableImageDecoder.cpp).

During the early run, the UI tool repeatedly returned `cgWindowNotFound` for both SmartShot and System Settings. Window access recovered in the 11:27 continuation. The error recurred after the later rectangle-editor checks, while the exact development-app process remained alive. These observations establish an interaction blocker, not a confirmed application crash.

Remaining acceptance includes controlled-content native Smart/Region/Long geometry, the broader editing matrix, clipboard pixels and private-copy suppression, wider history retention/restart cases, actual microphone recording, A/V sync, recording failure/sustained cases, Safari capture/import, current X compatibility, and multiple displays. Existing automated passes do not close these items.

## Resumed Editor Run at 11:27

Window access recovered for the same `EditorGIFFixedDerivedData` artifact. No production source changed and no automated suite was rerun during this continuation.

- The packaged native host accepted controlled PNG request `6cdc4b45-0999-4102-93a1-269b11ce9113`; the app displayed the expected fixture and created history item `37542f00-0e58-4e0a-900e-396dcf4a86fa`.
- Adding a Number annotation immediately displayed Flatten. Undo removed Flatten and enabled Redo. Redo restored the visible red number 1 and Flatten. No intervening save or parent-model action was needed.
- After resetting the edits and choosing Crop, a native drag from `(351, 156)` to `(823, 494)` in the observed window produced a 556 x 398-point preview. The dimension label refreshed immediately.
- Quick Save wrote `SmartShot 2026-09-06 11.29.35.png`, **1112 x 796 pixels**. The actual file was visually inspected; its SHA-256 is `d66ccecebb29e4c8e30395c3338283fa383a68a62940fafd071c6726bbb2e02f`.
- Flatten replaced only this owned test item's PNG with a byte-identical copy of the cropped output, removed Flatten, and disabled Undo/reset. Adding a Number to the replacement editor immediately displayed Flatten again, verifying observation after editor replacement.
- The exact development app was quit and relaunched. The cropped test history item remained listed. Later in the same continuation it was reopened, visually matched the cropped fixture, and accepted further rectangle edits.
- The original 21 history files were checked against the September 5 backup and remained byte-for-byte unchanged. The new test item is tracked separately for cleanup.
- The new signature initially reported Screen Recording and Accessibility unavailable. With the user's existing reset/regrant authorization, both SmartShot-specific TCC entries were reset. The exact development bundle was selected through System Settings' file-picker folder tree, the Accessibility switch was enabled, and the exact app was restarted. Both permissions then reported Allowed. The earlier request for manual foreground assistance was resolved without further user action. No Keychain identity or password was used.

## Resumed Recording and Native Capture

| Case | Result | Evidence and limit |
| --- | --- | --- |
| Microphone denial | Pass: start guard; positive path pending | Repeated Allow actions still left the app reporting Not allowed. With microphone capture enabled, starting a recording showed `Allow Microphone access, then return and start the recording again.` Dismissing the alert restored Ready. No microphone recording occurred; microphone capture was turned off. |
| Current-display system audio | Pass: actual audio signal | With system audio on, microphone/pointer off, 30 fps, and a 1920-pixel maximum edge, Start/Stop wrote `SmartShot Recording 2026-09-06 12.01.39.mp4`: **59.3167 seconds, 1918 x 1248**, one video track and one audio track. Decoded 48 kHz PCM contained **59 onsets of the fixture's 880 Hz tone** at approximately one-second intervals. |
| Controlled recording scene and A/V sync | Pending | Three sampled video frames did not contain the recording-fixture marker or its clock. The system-audio result proves captured sound, but does not establish a controlled visual scene or A/V synchronization. Desktop frames remain private local evidence. |
| Fixed-build GUI GIF export | Pass | The app's GIF command and Save panel produced `SmartShot Recording 2026-09-06 12.01.39.gif`: **450 fully decodable frames, 1280 x 832, 30.00 seconds**. This verifies the duration fix through the actual new app and the 30-second export cap. |
| Recording cancellation | Pass | A second recording created a session-owned `capture.mov` under `SmartShotRecording/Working`. Cancel returned the app to Ready, emptied both Working and Completed directories, and created no additional MP4. |
| Region drag output | Pass: output creation and scale only | A native overlay drag produced history item `1acbe0e9-9e03-4031-8130-d18b21bbafd1`. Metadata records a 497.9167 x 373.4375-point region; the PNG is **996 x 747 pixels**, matching rounded 2x scaling. The tool exposed the transparent overlay without its underlying desktop, so controlled-content boundaries and exclusion of other UI are not claimed. |

Audio evidence is in `system-audio-recording.json`, generated with AVFoundation PCM decoding and a windowed 880 Hz detector. The media inspection helper reports the GIF in `system-audio-gif.json`. These inspect actual GUI-generated files, not synthetic recording fixtures. The browser tone and clock were stopped after the recording.

## Further Editor, Clipboard, and Safari Checks

- Reopening history item `37542f00-0e58-4e0a-900e-396dcf4a86fa` after the app restart displayed the expected cropped fixture. A native drag from `(700, 220)` to `(820, 300)` drew a red rectangle; Select then moved it downward by 140 displayed pixels. Delete removed it and Flatten, and Undo visibly restored the moved rectangle. These are preview observations; no additional rendered output was saved for this sequence.
- Further Reset/Redact actions encountered an invalid element ID followed by `cgWindowNotFound`. The development process remained alive. Opaque-redaction/magnifier interaction and the remaining tool matrix were not completed.
- Invoking Copy produced no observable status change. The available browser-session clipboard reader returned an empty list and did not establish the contents of the macOS pasteboard. Explicit Copy pixels and private automatic-copy suppression remain unverified.
- Safari successfully loaded the approved `http://127.0.0.1:18765/?case=visible` fixture. Its Extensions list showed Open in IINA only, while SmartShot Settings reported `Safari extension is enabled`. This discrepancy does not establish which registered version that status referred to.
- Safari's Developer pane showed Allow unsigned extensions off. The development extension was not listed, and no Safari capture/import ran. A separate confirmation to temporarily enable this security override was requested and remained unanswered; the override was not enabled. Later Safari window reads timed out. No existing browser extension was removed.

## Early-Run Evidence and Cleanup

- Logs and result bundles remain in the private evidence root. Media reports are `video-only.json`, `video-only-gif.json`, and `video-only-timing-fixed.json`.
- This continuation's two known test history items and five generated output files were moved into `runtime-history` and `runtime-outputs`. The live history is back to the original 21 files (seven entries), all byte-for-byte unchanged. The Chrome native-host manifest is also byte-for-byte unchanged.
- Output is PNG; system audio, microphone, pointer, and Private mode are off. Recording settings remain 30 fps and a 1920-pixel maximum edge. Native window/save-panel bookkeeping is not reset wholesale.
- The local fixture server was not restarted. The installed app and unpacked Chrome extension were not replaced. The new temporary app was stopped, and both development app registrations used in this continuation were removed. `editor-cleanup.json` records the cleanup and archived-file hashes.
- Desktop video, GIFs, and extracted frames remain local only; no media was added to the repository or uploaded.

## Resumed-Run Cleanup

- The two resumed-run history items and three generated outputs were archived to `runtime-history` and `runtime-outputs`. `resumed-cleanup.json` records their sizes and SHA-256 hashes. The live history contains the original **21 files / seven entries**, all byte-for-byte equal to the baseline. The Chrome native-host manifest is also unchanged.
- The exact temporary app process was stopped and its app/extension registrations removed. A final process check found it absent; PlugInKit listed only the installed **0.2.1** extension under `/Applications/SmartShot.app`. The installed app was not replaced.
- System audio was restored to its backed-up off value with `defaults` after GUI window access failed. Microphone, pointer, and Private mode are off; output remains PNG, with 30 fps and a 1920-pixel maximum recording edge. The 30 fps value uses the source default because no preference override exists. No full preference-file replacement or TCC reset was performed during cleanup.
- Recording Working and Completed directories are empty. The fixture tone/clock had already stopped, and the local test server was stopped; a final connection attempt to port 18765 failed as expected. No recording or test process was left running.
- The existing native result bundle was reread and confirmed **205 passed, zero failed/skipped**. No production source changed in this resumed run; the native and browser suites were not rerun. Documentation whitespace and local-link checks passed.
