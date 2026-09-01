#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
cd "$PROJECT_ROOT"

for forbidden in \
  'import PostHog' \
  'import Sparkle' \
  'api.openai.com/v1/audio' \
  's.overseed.ai' \
  'overseedai.github.io/overwhisper/appcast'; do
  if rg -n --glob '*.swift' --glob '*.plist' --glob 'Package.swift' "$forbidden" Overwhisper Package.swift; then
    print -u2 "Privacy audit failed: forbidden runtime surface '$forbidden' remains."
    exit 1
  fi
done

if rg -n 'URLSession|http://' \
  Overwhisper/Audio \
  Overwhisper/Transcription \
  Overwhisper/SpeechLayer; then
  print -u2 "Privacy audit failed: speech/audio code contains a network API."
  exit 1
fi

if rg -n -U 'AppLogger\.[^(]+\([^)]*localizedDescription' Overwhisper --glob '*.swift'; then
  print -u2 "Privacy audit failed: a dynamic error description can reach unified logging."
  exit 1
fi

print "Privacy source audit passed."
