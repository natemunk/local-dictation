# Rewrite reliability follow-up — September 10, 2026

This follows Claude's review of the selection-aware rewrite implementation.
All pre-existing dirty work remains intact on `main` at
`e3ec7ed1037d7d592db747e09a820161a4f06cd6`. Nothing was committed, pushed,
installed, or deployed during this follow-up. No settings were changed and no
microphone was recorded.

## Changes

- Close/resume restores a canceled revision's completed draft, including manual
  edits and its version/provenance. Late provider output cannot overwrite it.
  Closing a first generation without a completed draft returns Resume to the
  preserved source/options, rather than an unacceptably incomplete result.
- Original remains immutable. Edits while viewing it become a separate draft;
  Next returns to the last-viewed draft. The five-version bound remains enforced.
- Unknown or protected selection access never silently reads the clipboard.
  Explicit Use current clipboard skips confirmation on an empty recovery screen
  and preserves the invocation's voice/options intent. Recovery explains when
  that choice will start instruction recording. Own-process invocation deliberately
  uses a labeled clipboard source without reading History or other app content.
- Capture invalidated by an app switch gives a beep and does not open a popup in
  the newly selected app. Missing AX attributes remain unknown, not empty.
- Insert After leaves the selected range unchanged during preflight; its caret
  collapse and verification happen in the shared insertion guard immediately
  before paste. Clipboard/focus checks and no automatic retry remain intact.
- The instructions field implements Return to rewrite and Shift+Return to insert
  a newline at the editing position. Command+Return retains its existing action.
- Dismissing a dictation rewrite returns its raw message to ordinary Preview,
  both before and after source finalization. A dismissal during the awaited
  history write also falls back to Preview. The popup closes/restores focus
  before the callback can open Preview.
- iPhone admission refuses work while local writing is running or draining;
  it does not cancel the writer, including when another remote lease exists.
  Desktop dictation still preempts remote inference. Remote requests are not queued.
- Privacy documentation now accurately separates the 250 ms selection-operation
  deadline from the subsequent synchronous legacy destination capture.

## Verified in this follow-up

- Full Swift suite: **293 tests / 38 suites passed**, with
  `LD_TEST_APPLE_WRITER=1`. This includes three real Apple Foundation Models
  smoke examples using only synthetic text, not microphone recordings.
- Thirteen new regression tests cover draft recovery, late output/drainage,
  version bounds/edits/provenance, clipboard source routing and voice intent,
  missing/invalid AX values, selection precedence, remote admission, and handled
  Return/Escape keyups. The previous original-navigation test now expects the
  last-viewed draft rather than the oldest version.
- The explicitly authorized native AppKit acceptance host passed on newly created
  **plain and rich TextEdit documents**: Replace, Insert After, one-event Undo,
  surrounding formatting, duplicate acceptance suppression, changed-selection
  refusal, post-preflight failure without caret movement, preset arrow navigation,
  instructions Return/Shift+Return, and Command+Return delivery.
- The host compiles current production UI/selection/delivery sources with explicit
  speech/model stubs. It never records audio. Its synthetic clipboard changes are
  restored only while it still owns the clipboard; prior clipboard data is neither
  printed nor persisted. Only its disposable documents are closed.
- One initial host attempt timed out before selection capture completed; its cause
  was not established and it is not counted as a pass. A subsequent run exposed
  native Shift+Return handling, which was corrected; the final plain/rich run passed.
- Two opt-in synthetic UI render tests passed; the options view was visually inspected
  and the expanded keyboard help fits without clipping.
- Privacy source audit, benchmark fixture verification, and `git diff --check` pass.
- Production release build passes. SHA-256:
  `9c3361191a6246f64e0c9d47230a4c77ee00a0178fd170de10a42c9f9e56b573`.
- Installed app remains the earlier build, SHA-256:
  `8e38e64c147467db7db3d9752718b82d476671c962df0854b671a7c7db115eef`.
  Worker deployment was not changed or verified by this Mac-only follow-up.

Local ephemeral logs: `/tmp/ld-reliability-tests.log`,
`/tmp/ld-reliability-editor.log`, `/tmp/ld-reliability-build.log`.

## Install and test manually

When ready to replace the installed app, run `./setup` from the repository.
It tests, builds, signs with the existing local signing configuration, installs,
and launches the app. This was **not** run during this follow-up.

1. **Basic dictation:** Hyper+D, speak a short message, finish normally. Confirm
   speed and insertion still feel normal in your everyday destination apps.
2. **Dictation plus rewrite:** Hyper+D, speak the message, Hyper+C, speak instructions,
   Return. Review and accept. Repeat, but use Escape while instructions are pending
   and again after a result appears: your original message should return to Preview.
   Cancel an active generation first, then Escape again to dismiss its review.
3. **Clipboard recovery:** copy disposable text, focus an editor with unavailable
   selection access, Hyper+C. Confirm nothing is silently selected from the clipboard.
   Choose Use current clipboard: no discard sheet appears on an empty screen and
   instruction recording starts visibly. Invoke Options instead and verify recovery
   stays in Options. From Local Dictation History, verify source is labeled clipboard.
4. **Draft recovery:** create a rewrite, edit its result, start a revision, close
   the window mid-generation, then choose Resume Last Rewrite. Expect the last
   completed edited draft. Also close/reopen an already completed manual edit.
5. **Original and versions:** generate two drafts, view Original, edit it, press
   Next. Expect the last-viewed draft; the edited Original is available as a separate
   version. Returning to Original should still show the untouched original text.
6. **TextEdit:** select disposable text and invoke Hyper+C twice for options. Test
   Return and Shift+Return in instructions, Replace, Insert After, and one Undo.
   Change the selection before acceptance: delivery should refuse with the draft
   recoverable. Other editors deliberately remain Copy-only for replacement.
7. **iPhone priority:** while a Mac rewrite is generating, start an iPhone request.
   The Mac rewrite must continue; the phone should show the existing busy/fallback
   flow, with any cloud fallback visibly disclosed. After local writing drains,
   retry. Also confirm Hyper+D retains priority during a phone stream.
8. **Real environment:** try normal app switching, Spaces/full screen, keyboard
   utility conflicts, and microphone/device changes. These remain manual acceptance.

Real microphone handoff, installed-app Preview/focus behavior, cross-editor AX,
and real-iPhone audio/partials/fallback have not been verified by the synthetic
checks above. A WebSocket upgrade or fast post-Stop response alone would not prove
live audio transmission or partial results while recording.

## Re-run automated checks

```sh
# Use the explicit Xcode Swift path if the active command-line shim is broken.
LD_TEST_APPLE_WRITER=1 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --cache-path .build/swiftpm-cache
zsh scripts/privacy-audit.sh
bash Benchmark/verify-fixtures.sh
```

Only with permission to temporarily use disposable TextEdit documents and the
clipboard (never in CI):

```sh
LD_TEST_SELECTION_EDITOR=1 bash scripts/test-rewrite-editor.sh
```
