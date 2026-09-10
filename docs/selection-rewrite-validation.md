# Selection-aware rewrite validation — September 10, 2026

This records the initial selection implementation. For the subsequent reliability
fixes and current test/build results, see [rewrite reliability validation](rewrite-reliability-validation.md).

## Implemented

The existing voice rewrite now uses a content-only session model for source kind,
immutable original, reply purpose, bounded versions, and model provenance. Active
dictation remains first priority; explicit selection capture precedes clipboard
fallback. Unknown selection access opens recovery choices without reading the
clipboard or starting the microphone. Local Dictation's own process is excluded.

Selected text uses a nonactivating key panel. TextEdit text areas alone are enabled
for Replace and Insert after selection. Other readable selections support rewriting
and Copy. Insertion shares TextInserter's existing clipboard ownership/cancellation
checks, adding selection validation before clipboard mutation and immediately
before paste. Insert-after verifies the collapsed caret; terminals and protected
fields never qualify. Reply drafts require direction and use Copy. No action sends
a message. Empty results cannot replace a selection.

Hyper+C during completed-result review starts a spoken revision using the edited
draft and original reference. During listening it opens options; during inference
it never starts another job. Previous/Next/Original and Resume Last Rewrite retain
one memory-only session. Failure/cancellation preserves prior completed output.
Manual edits without model generation do not claim Apple-model provenance when
accepted back into dictation history. Selected/clipboard text and instructions
never enter history or sync.

## Verification

- Full Swift suite: 280 tests across 38 suites passed. Focused additions cover
  source/session state, combined context limits, reply direction and Copy defaults,
  version bounds/branching/provenance, follow-up voice cancellation and source
  ordering, editor capability refusal, preflight clipboard preservation, final
  selection failure, concurrent copying, and bounded AX-operation drainage.
- Explicit synthetic Apple-model checks passed, including restoring Friday from
  an original reference omitted from the current draft. These are smoke examples,
  not a general guarantee of factual accuracy or a latency benchmark.
- Synthetic listening/result/options views were rendered and inspected. Listening
  has a prominent microphone indicator; the result exposes its source and action.
- The explicitly authorized `scripts/test-rewrite-editor.sh` acceptance host passed
  with newly created plain-text and rich-text TextEdit documents. It verified exact
  selection capture, nonactivating panel/key focus, Replace, Insert-after, duplicate
  acceptance suppression, unchanged formatting outside the selection, one-event
  Undo, changed-selection refusal before clipboard mutation, reused-popup arrow
  navigation, Return generation, and Cmd+Return delivery. Fixtures include emoji
  and multiline text. No real microphone or model inference runs in this host.
- The host compiles the actual session/UI/selection/paste sources. Its unrelated
  speech, availability, logging/signpost dependencies are explicit test stubs;
  production writer behavior is separately checked through Swift tests.
- Initial XCTest-host UI attempts exited before reporting completion and were NOT
  counted as passes. A native AppKit run loop resolved the harness problem. Fixed
  short Undo delays were replaced with bounded editor-state observations, without
  retrying paste or Undo. Keyboard acceptance exposed reused-popup focus retention;
  restoring focus for each new source fixed the tested flow.
- Privacy source audit, benchmark fixtures, and whitespace checks passed.

## Boundaries and remaining acceptance

No microphone was recorded. Real speech handoff, device changes, live partials,
Hyper+C precedence against other shortcut utilities, Spaces/full-screen transitions,
and installed-app voice behavior still require user acceptance. Messages, Safari,
Slack, and Codex replacement are not enabled or claimed; their selection readability
and editing behavior need separate disposable-document checks.

AX validation and synthetic paste are separate cross-process operations, not an
atomic editor transaction. The app never reports a posted event as universal proof
of insertion, retries it automatically, or restores the clipboard after a product
paste. Draft recovery remains available. The opt-in test harness separately keeps
clipboard formats in memory and restores them only while it still owns the tested
clipboard state; it never prints or persists the prior clipboard.

## Build and installation

Source remains on main based on `e3ec7ed1037d7d592db747e09a820161a4f06cd6` with prior
uncommitted work preserved. The production executable passed a SwiftPM release build with SHA-256
`25cf3a4b8d6c8f1eb6cc98d82a5eabd4d6b31b0c004fd85699f91b9055a4b673`.
No commit, push, installation, system-setting change, or Cloudflare deployment is
part of this change. The installed app was checked separately and still has SHA-256
`8e38e64c147467db7db3d9752718b82d476671c962df0854b671a7c7db115eef` (the preceding voice
rewrite build). Source/build success is distinct from installation and device use.

To rerun the foreground editor acceptance, first obtain permission to use disposable
TextEdit documents and temporarily use the clipboard, then run:

```sh
LD_TEST_SELECTION_EDITOR=1 bash scripts/test-rewrite-editor.sh
```

Do not run this interactive check in CI. The normal Swift suite remains synthetic.
