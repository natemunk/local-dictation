#!/bin/bash
set -euo pipefail
# Explicitly authorized foreground/clipboard acceptance only. Never run in CI.
if [[ "${LD_TEST_SELECTION_EDITOR:-}" != "1" ]]; then
  echo "Set LD_TEST_SELECTION_EDITOR=1 only after permission to use disposable TextEdit documents and the clipboard."
  exit 2
fi
cd "$(dirname "$0")/.."
SWIFT_COMPILER="${LOCAL_DICTATION_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
mkdir -p .build/editor-acceptance
"$SWIFT_COMPILER" -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -swift-version 5 -parse-as-library -o .build/editor-acceptance/runner \
  Overwhisper/Writing/ClipboardWriter.swift \
  Overwhisper/Writing/ClipboardRewriteModel.swift \
  Overwhisper/Writing/RewriteSession.swift \
  Overwhisper/Core/VoiceRewriteFlow.swift \
  Overwhisper/Output/DictationDestination.swift \
  Overwhisper/Output/TextInserter.swift \
  Overwhisper/Output/RewriteSelection.swift \
  Overwhisper/UI/ClipboardRewriteWindow.swift \
  Tests/Support/RewriteEditorAcceptanceStubs.swift \
  Tests/Support/RewriteEditorAcceptance.swift
.build/editor-acceptance/runner
