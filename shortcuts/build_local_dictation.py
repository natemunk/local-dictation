#!/usr/bin/env python3
"""
Local Dictation — record on iPhone, transcribe on the Mac (Cloudflare fallback),
copy the text, and hand cloud-fallback results to the Dictation Inbox PWA.

Contract: ~/projects/local-dictation/docs/unified-history.md (§2, §6) and
docs/iphone-shortcut.md. Flow:

 1. Two Text actions hold the SHORTCUT gateway service token (edit after import).
 2. Record Audio (normal quality, starts immediately, stops on tap).
 3. Generate UUID → X-Request-ID.
 4. POST the recording as the raw body to https://dictate.natemunk.com/v1/transcriptions.
    Shortcuts cannot read a fresh recording's duration, so the header declares the
    10-minute maximum; the Mac measures the real length after conversion.
 5. Read text / route / history_state from the JSON.
 6. Copy text, notify "Copied · Mac" or "Copied · Cloud fallback".
 7. If history_state is not saved_on_mac, open /app/import#… so the PWA keeps it
    (fragment never reaches a server; >16 000 chars switches to clipboard mode).
 8. Output the text for other shortcuts.

A failed HTTP request stops the shortcut before Copy to Clipboard, so the
clipboard is never overwritten on error.

Usage:
    python3 examples/local_dictation.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shortcut_builder import Shortcut, _make_token_attachment, _uuid

GATEWAY = "https://dictate.natemunk.com"
TRANSCRIBE_URL = f"{GATEWAY}/v1/transcriptions"
IMPORT_URL = f"{GATEWAY}/app/import"
MAX_FRAGMENT_TEXT_CHARACTERS = 16_000
CLIENT_ID_PLACEHOLDER = "PASTE-SHORTCUT-CLIENT-ID.access"
CLIENT_SECRET_PLACEHOLDER = "PASTE-SHORTCUT-CLIENT-SECRET"


def build() -> Path:
    s = Shortcut("Local Dictation")

    s.comment(
        "Local Dictation\n"
        "1. Paste your SHORTCUT gateway service token into the two Text fields below.\n"
        "   (Zero Trust → Access → Service Auth → Service Tokens. Use the Shortcut token,\n"
        "   not the PWA or origin token.)\n"
        "2. Run once from the Shortcuts app to grant microphone access.\n"
        "3. Assign to the Action Button or Back Tap.\n"
        "Never put the token in the shortcut name, URL, or a notification."
    )
    client_id = s.text(CLIENT_ID_PLACEHOLDER)
    client_secret = s.text(CLIENT_SECRET_PLACEHOLDER)

    audio = s._add_action("is.workflow.actions.recordaudio", {
        "WFRecordingCompression": "Normal",
        "WFRecordingStart": "Immediately",
        "WFRecordingEnd": "On Tap",
    }, output_name="Audio File")

    request_id = s._add_action("is.workflow.actions.generateuuid", {}, output_name="UUID")

    response = s._add_action("is.workflow.actions.downloadurl", {
        "WFURL": TRANSCRIBE_URL,
        "WFHTTPMethod": "POST",
        "WFHTTPBodyType": "File",
        "WFRequestVariable": _make_token_attachment(audio),
        "WFHTTPHeaders": s._make_dict_value({
            "Content-Type": "audio/mp4",
            "CF-Access-Client-Id": client_id.ref,
            "CF-Access-Client-Secret": client_secret.ref,
            "X-Request-ID": request_id.ref,
            "X-Dictation-Client": "shortcut",
            "X-Dictation-Mode": "clean",
            "X-Allow-Cloud-Fallback": "true",
            "X-Audio-Duration-Seconds": "600",
        }),
    }, output_name="Contents of URL")

    text = s.get_dict_value(response, "text")
    route = s.get_dict_value(response, "route")
    history_state = s.get_dict_value(response, "history_state")

    s.copy_to_clipboard(text)

    route_if = s.if_start(route, "Equals", "cloud_fallback")
    s.show_notification("Local Dictation", "Copied · Cloud fallback")
    s.otherwise(route_if)
    s.show_notification("Local Dictation", "Copied · Mac")
    s.if_end(route_if)

    # Hand the transcript to the Dictation Inbox only when the Mac did not save it.
    sync_if = s.if_start(history_state, "Does Not Equal", "saved_on_mac")

    encoded_text = s._add_action("is.workflow.actions.urlencode", {
        "WFEncodeMode": "Encode",
        "WFInput": _make_token_attachment(text),
    }, output_name="URL Encoded Text")
    now = s._add_action("is.workflow.actions.date", {
        "WFDateActionMode": "Current Date",
    }, output_name="Date")
    iso_now = s._add_action("is.workflow.actions.format.date", {
        "WFInput": _make_token_attachment(now),
        "WFDateFormatStyle": "ISO 8601",
        "WFISO8601IncludeTime": True,
    }, output_name="Formatted Date")
    encoded_now = s._add_action("is.workflow.actions.urlencode", {
        "WFEncodeMode": "Encode",
        "WFInput": _make_token_attachment(iso_now),
    }, output_name="URL Encoded Text")
    characters = s.count(text, "Characters")

    # Numeric comparison uses WFNumberValue, not the string comparison field.
    size_group = _uuid()
    s.actions.append({
        "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
        "WFWorkflowActionParameters": {
            "WFInput": _make_token_attachment(characters),
            "WFCondition": 3,  # Is Less Than
            "WFNumberValue": MAX_FRAGMENT_TEXT_CHARACTERS + 1,
            "GroupingIdentifier": size_group,
            "WFControlFlowMode": 0,
        },
    })
    s.open_url(
        f"{IMPORT_URL}#v=1&id={request_id.ref}&ts={encoded_now.ref}"
        f"&mode=clean&route={route.ref}&client=shortcut&text={encoded_text.ref}"
    )
    s.otherwise(size_group)
    s.open_url(
        f"{IMPORT_URL}#v=1&id={request_id.ref}&ts={encoded_now.ref}"
        f"&mode=clean&route={route.ref}&client=shortcut&clipboard=1"
    )
    s.if_end(size_group)

    s.if_end(sync_if)

    s.stop_and_output(text)

    output = Path(__file__).resolve().parent.parent / "shortcuts" / "local_dictation.shortcut"
    s.build(output)
    return output


if __name__ == "__main__":
    build()
