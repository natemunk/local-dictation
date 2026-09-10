# Deployment: September 8, 2026

The user authorized deploying the completed reliability fixes and installing the Mac update.
This records runtime release evidence separately from the implementation-only validation report.

## Released source

- Repository: `natemunk/local-dictation`, branch `main`, base `e3ec7ed1037d7d592db747e09a820161a4f06cd6`.
- All 59 files in the implementation SHA-256 manifest matched the tested source before deployment and after installation. All 56 Worker/PWA source, asset, test, package and configuration files matched tested staging.
- The previously completed validation passed 232 Swift tests (35 suites), 338 Worker/PWA tests (19 files), three TypeScript checks, privacy audit and benchmark scorer fixtures. No source changes required repeating those suites for this release.
- Production Swift compilation, stable signing and strict bundle/resource checks passed during installation. The Worker dry run and production upload passed.
- Changes remain uncommitted and unpushed. No signing identity, Access policy, credential or dictation setting was changed.

## Cloudflare Worker and PWA

- Active Worker version: `a20dfa59-083b-45c0-b217-617fd735eb35`.
- Deployment: `9c54ed0c-5263-471d-aa8e-abd8e43b159b`, created `2026-09-08T11:59:15Z`, serving 100%.
- PWA build: `2026-09-08-recovery-1`; shell cache v5.
- Rollback Worker version: `502febc2-027b-44d2-ac75-8e1e2401c157`.
- Wrangler reported a 503 while reading subdomain state after uploading. Deployment readback confirmed the new version was active; a separate subdomain read confirmed workers.dev and preview URLs remain disabled. No duplicate deployment was needed.
- Anonymous Node probes returned 200 for all 25 public files. All 24 non-HTML files match source byte-for-byte, including normal and query URLs for app.js, sw.js, sw-routing.js and build.js. HTML preserves the source with Cloudflare JavaScript Detection markup inserted before the closing body tag. Execution of that edge-added inline script was not tested.
- Public assets return no-cache and the restrictive CSP, including the explicit same-origin WSS endpoint.
- Anonymous API and Mac-origin requests returned 403. Unsigned /stream returned 403 with STREAM_ORIGIN_REFUSED, establishing the Worker ticket guard was reached.
- Python urllib probes returned generic 403 even for public assets; these did not establish application behavior. The successful Node probes provide asset and guard evidence.
- Existing secret bindings remain present. No authenticated transcription or history request was made in release verification.

## Installed Mac app

- Installed and relaunched `/Users/nmunk/Applications/Local Dictation.app` with the existing stable signing identity.
- Signed staged and installed executables are byte-identical. Installed __text, __const and __cstring sections match the production Swift build.
- Post-restart localhost health returned ready=true, busy=false, selected_engine=parakeetV2.
- Installed executable SHA-256: `439c0feded055ae6f54e14a6ad371fa4c71288af3d6c0e088b0aa0fd3cce9e23`.
- Running executable path was verified after restart; bundle identifier com.natemunk.LocalDictation, arm64, version 0.1.0/build 1. The generic version fields alone are not source provenance.
- A release-only temporary wrapper used the original setup workflow with an idle guard immediately before replacement. Two attempts deferred while dictation was busy; the successful attempt waited for five continuous idle seconds before restarting.
- Previous app backup: `/Users/nmunk/Library/Application Support/Local Dictation/Installed App Backups/Local Dictation previous 20260908-080335.app`.

## iPhone adoption and remaining acceptance

Finish recording and copy unsaved work. Open Dictation online to allow the new shell to download,
then close its Safari tabs and fully close the Home Screen app. Reopen and verify Settings →
Diagnostics shows App 2026-09-08-recovery-1. If already running the new shell, use its Update ready
action while idle. No website-data reset, key removal or reinstall is required.

This release verification did not record a microphone, inspect transcript history, use the real
clipboard, or certify live iPhone PCM/partials. Real iPhone testing must confirm audio receipts and
nonempty partial text while recording, then final batch results after Stop. See hardening-validation.md
for the remaining recovery, priority, focus and device acceptance scenarios.
