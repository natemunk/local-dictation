#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d /private/tmp/local-dictation-benchmark.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

developer_dir=${DEVELOPER_DIR:-}
if [ -z "$developer_dir" ]; then
  developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null || true)
fi
if [ -z "$developer_dir" ]; then
  developer_dir=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR="$developer_dir"

swiftc_path="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
if [ ! -x "$swiftc_path" ]; then
  swiftc_path="$developer_dir/usr/bin/swiftc"
fi
if [ ! -x "$swiftc_path" ]; then
  swiftc_path=$(/usr/bin/xcrun --find swiftc 2>/dev/null || true)
fi

sdk_path="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ ! -d "$sdk_path" ]; then
  sdk_path="$developer_dir/SDKs/MacOSX.sdk"
fi
if [ ! -d "$sdk_path" ]; then
  sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
fi

if [ ! -x "$swiftc_path" ] || [ ! -d "$sdk_path" ]; then
  printf '%s\n' "A Swift compiler and macOS SDK are required under DEVELOPER_DIR: $developer_dir" >&2
  exit 1
fi

module_cache="$work_dir/module-cache"
mkdir -p "$module_cache"

SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$module_cache" \
  "$swiftc_path" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$module_cache" \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx15.0 \
  "$repo_root"/Benchmark/*.swift \
  -o "$work_dir/local-dictation-benchmark"

"$work_dir/local-dictation-benchmark" \
  --manifest "$repo_root/Benchmark/Fixtures/corpus.jsonl" \
  --results "$repo_root/Benchmark/Fixtures/passing-results.jsonl" \
  >"$work_dir/passing.json" \
  2>"$work_dir/passing.txt"

jq -e '.selection.candidate == "whisperkit-small.en"' "$work_dir/passing.json" >/dev/null
jq -e '.selection.status == "selected_passing_candidate"' "$work_dir/passing.json" >/dev/null
jq -e '.selection.reason | contains("within one weighted WER point")' "$work_dir/passing.json" >/dev/null
jq -e '.candidates[] | select(.candidate == "whisperkit-large-v3_turbo") | .domain_weighted_wer > .standard_wer' "$work_dir/passing.json" >/dev/null
jq -e '.candidates[] | select(.candidate == "parakeet-v2") | .p95_latency_milliseconds == 160' "$work_dir/passing.json" >/dev/null

jq -s 'map({key: .id, value: .reference}) | from_entries' \
  "$repo_root/Benchmark/Fixtures/corpus.jsonl" >"$work_dir/references.json"
jq -c --slurpfile references "$work_dir/references.json" \
  'if .candidate == "parakeet-v2" or .candidate == "whisperkit-small.en" then .latency_ms = 100 | .transcript = $references[0][.sample_id] else . end' \
  "$repo_root/Benchmark/Fixtures/passing-results.jsonl" >"$work_dir/exact-tie.jsonl"
"$work_dir/local-dictation-benchmark" \
  --manifest "$repo_root/Benchmark/Fixtures/corpus.jsonl" \
  --results "$work_dir/exact-tie.jsonl" \
  >"$work_dir/exact-tie.json" \
  2>"$work_dir/exact-tie.txt"
jq -e '.selection.candidate == "parakeet-v2"' "$work_dir/exact-tie.json" >/dev/null
jq -e '.selection.reason | contains("exact tie")' "$work_dir/exact-tie.json" >/dev/null

jq -c 'select(.candidate == "parakeet-v2") | .processing_seconds = 100' \
  "$repo_root/Benchmark/Fixtures/passing-results.jsonl" >"$work_dir/no-pass.jsonl"
set +e
"$work_dir/local-dictation-benchmark" \
  --manifest "$repo_root/Benchmark/Fixtures/corpus.jsonl" \
  --results "$work_dir/no-pass.jsonl" \
  >"$work_dir/no-pass.json" \
  2>"$work_dir/no-pass.txt"
no_pass_status=$?
set -e
[ "$no_pass_status" -eq 2 ]
jq -e '.selection.status == "temporary_fallback_no_candidate_passed"' "$work_dir/no-pass.json" >/dev/null
jq -e '.selection.candidate == "parakeet-v2"' "$work_dir/no-pass.json" >/dev/null
jq -e '.selection.raycast_disposition == "keep"' "$work_dir/no-pass.json" >/dev/null
jq -e '.candidates[0].gates[] | select(.id == "real_time_factor") | .passed == false' "$work_dir/no-pass.json" >/dev/null

for gate_case in crash content_loss latency_failure; do
  case "$gate_case" in
    crash)
      jq_filter='select(.candidate == "parakeet-v2") | if .sample_id == "synthetic-technical-001" then .status = "crash" else . end'
      gate_id=crashes
      ;;
    content_loss)
      jq_filter='select(.candidate == "parakeet-v2") | if .sample_id == "synthetic-technical-001" then .content_loss = true else . end'
      gate_id=content_loss
      ;;
    latency_failure)
      jq_filter='select(.candidate == "parakeet-v2") | if .sample_id == "synthetic-technical-001" then .latency_failure = true else . end'
      gate_id=latency
      ;;
  esac
  jq -c "$jq_filter" "$repo_root/Benchmark/Fixtures/passing-results.jsonl" >"$work_dir/$gate_case.jsonl"
  set +e
  "$work_dir/local-dictation-benchmark" \
    --manifest "$repo_root/Benchmark/Fixtures/corpus.jsonl" \
    --results "$work_dir/$gate_case.jsonl" \
    >"$work_dir/$gate_case.json" \
    2>"$work_dir/$gate_case.txt"
  gate_status=$?
  set -e
  [ "$gate_status" -eq 2 ]
  jq -e --arg gate "$gate_id" '.candidates[0].gates[] | select(.id == $gate) | .passed == false' \
    "$work_dir/$gate_case.json" >/dev/null
done

printf '%s\n' "Benchmark fixture verification passed."
