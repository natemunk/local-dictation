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

if rg -n '"(kv_namespaces|d1_databases|r2_buckets|durable_objects|queues|analytics_engine_datasets|workflows)"' \
  cloud/iphone-gateway/wrangler.jsonc; then
  print -u2 "Privacy audit failed: the iPhone gateway declares application storage or a queue."
  exit 1
fi

if rg -n 'console\.(log|warn|error)\([^)]*(text|audio|request|response|headers|exception|history|entries|operations|body|token)' \
  cloud/iphone-gateway/src --glob '*.ts'; then
  print -u2 "Privacy audit failed: content-bearing gateway data may reach application logs."
  exit 1
fi

PWA_ROOT="cloud/iphone-gateway/public"
PWA_GLOBS=(--glob '*.js' --glob '*.html' --glob '*.css' --glob '*.webmanifest')

if [[ ! -d "$PWA_ROOT" ]]; then
  print "Privacy audit note: $PWA_ROOT does not exist; PWA asset checks were skipped."
else
  for forbidden_api in \
    'innerHTML' \
    'outerHTML' \
    'insertAdjacentHTML' \
    'document\.write' \
    'eval\(' \
    'new Function'; do
    if rg -n "$forbidden_api" "$PWA_ROOT" $PWA_GLOBS; then
      print -u2 "Privacy audit failed: PWA assets use a dynamic-markup or dynamic-code API."
      exit 1
    fi
  done

  # Only the gateway's own origin may appear in shipped PWA assets. Documentation
  # links belong in Markdown, which is not scanned here.
  if rg -n -P 'https?://(?!dictate\.natemunk\.com)' "$PWA_ROOT" $PWA_GLOBS; then
    print -u2 "Privacy audit failed: PWA assets reference a third-party origin."
    exit 1
  fi

  if rg -n -U '<script[^>]*>[^<]*\S[^<]*</script>' "$PWA_ROOT" $PWA_GLOBS; then
    print -u2 "Privacy audit failed: PWA assets contain an inline script block."
    exit 1
  fi

  if rg -n '\sstyle\s*=\s*"' "$PWA_ROOT" $PWA_GLOBS; then
    print -u2 "Privacy audit failed: PWA assets contain an inline style attribute."
    exit 1
  fi

  if rg -n '\son[a-z]+\s*=\s*"' "$PWA_ROOT" $PWA_GLOBS; then
    print -u2 "Privacy audit failed: PWA assets contain an inline event-handler attribute."
    exit 1
  fi
fi

print "Privacy source audit passed."
