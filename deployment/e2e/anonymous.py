"""Hosted anonymous Con recording checks; consumes this IP's three daily allowances."""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit
import uuid
import wave

import hosted
from playwright.sync_api import sync_playwright, expect

PHASE = "startup"
# Public synthetic speech fixture from lifenizer/e2e/fixtures/speech-sample.wav.
SPEECH_SHA256 = "40caa4d41e4f0458f9ccaaaa1a16dff9fe47c14f5bc5d40713bde536325f967a"


def validate_fixture(path):
    if hashlib.sha256(path.read_bytes()).hexdigest() != SPEECH_SHA256:
        raise ValueError("Use the known public synthetic English speech fixture")
    with wave.open(str(path), "rb") as audio:
        assert audio.getparams()[:3] == (1, 2, 16000)
        assert audio.getnframes() / audio.getframerate() == 11


def pcm_wav(seconds):
    stream = io.BytesIO()
    with wave.open(stream, "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        audio.writeframes(bytes(seconds * 16000 * 2))
    return stream.getvalue()


def status(page):
    return page.evaluate("""async () => {
      const response = await fetch('/api/transcription/status');
      return {status: response.status, body: await response.json()};
    }""")


def segment(page, seconds, spoof_ip=False):
    # Send synthetic PCM through the same browser routing as the app; never attach a token.
    return page.evaluate("""async ({audio,recordingId,spoof}) => {
      const headers = {'Content-Type':'audio/wav'};
      if (spoof) headers['X-Forwarded-For'] = '198.51.100.71';
      const response = await fetch('/api/transcription/segment?recordingId='+recordingId+'&segment=0&language=en', {
        method:'POST', headers, body:Uint8Array.from(atob(audio), character => character.charCodeAt(0))});
      return {status:response.status, body:await response.json()};
    }""", {"audio": base64.b64encode(pcm_wav(seconds)).decode("ascii"), "recordingId": str(uuid.uuid4()), "spoof": spoof_ip})


def check_remaining(page, remaining):
    response = status(page)
    assert response["status"] == 200
    assert response["body"]["available"] is True
    assert response["body"]["remainingRecordings"] == remaining
    assert response["body"]["dailyLimit"] == 3
    assert response["body"]["maxDurationSeconds"] == 60


def english_recording_language(page):
    hosted.settings(page)
    hosted.open_item(page, "Sprache der Aufnahmen")
    page.get_by_role("radio", name="English", exact=True).click()
    expect(page.get_by_text("Einstellungen", exact=True)).to_be_visible()
    hosted.back(page)
    expect(page.get_by_text("Karte", exact=True).last).to_be_visible()


def open_quick_add(page):
    page.mouse.click(page.viewport_size["width"] * .58, page.viewport_size["height"] * .48)
    expect(page.get_by_text("Neue Geschichte", exact=True)).to_be_visible()


def record_story(page, number, result):
    global PHASE
    PHASE = "anonymous story recording " + str(number)
    title = "E2E anonyme Aufnahme " + str(number)
    notes = "Synthetische Notiz bleibt erhalten."
    print("Guest speech recording " + str(number) + " started", flush=True)
    responses = []
    def capture(response):
        if urlsplit(response.url).path == '/api/transcription/segment':
            responses.append(response.status)
    page.on('response', capture)
    result['last_recording_transcription_http_statuses'] = responses
    open_quick_add(page)
    hosted.field(page, "Was ist hier passiert?", notes)
    hosted.field(page, "Titel (optional)", title)
    hosted.click(page, "Aufnahme starten")
    expect(page.get_by_text("Aufnahme beenden", exact=True)).to_be_visible()
    # The 11-second public speech includes 'country'; capture the final tail too.
    page.wait_for_timeout(13000)
    hosted.click(page, "Aufnahme beenden")
    expect(page.get_by_role("button", name="Geschichte speichern", exact=True)).to_be_enabled(timeout=90000)
    transcript = page.get_by_role("textbox", name=re.compile(r"Was ist hier passiert\?"))
    # Flutter refreshes an inactive semantic input from its controller on focus.
    transcript.click()
    expect(transcript).to_be_focused()
    expect(transcript).to_have_value(re.compile("country", re.I), timeout=90000)
    page.remove_listener('response', capture)
    assert responses and all(status == 200 for status in responses)
    assert transcript.input_value().startswith(notes), "Typed notes were overwritten by transcription"
    print("Guest speech recording " + str(number) + " transcribed", flush=True)
    hosted.click(page, "Geschichte speichern")
    hosted.click(page, "Geschichten")
    hosted.open_item(page, title)
    expect(page.get_by_text(re.compile("country", re.I)).last).to_be_visible()
    expect(page.get_by_text(re.compile(re.escape(notes))).last).to_be_visible()
    hosted.playback(page)
    hosted.back(page)
    hosted.click(page, "Karte")


def run(args):
    global PHASE
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    result = {"completed": False, "anonymous_daily_allowances_consumed": 0,
              "initial_remaining": args.initial_remaining,
              "server_path": "isolated_deployed_backend" if args.api_forward else
                  "isolated_ingress" if any("--host-resolver-rules=" in arg for arg in args.browser_arg) else "public_ingress"}
    errors = []
    try:
        validate_fixture(args.audio_fixture)
        with hosted.chromium(args, output) as endpoint, sync_playwright() as playwright:
            browser = playwright.chromium.connect_over_cdp(endpoint)
            context = browser.new_context(viewport={"width": 1440, "height": 900}, locale="de-DE", permissions=["microphone"])
            if args.api_forward:
                def forward_transcription(route):
                    request = route.request
                    original = urlsplit(request.url)
                    headers = {name: value for name, value in request.all_headers().items()
                               if name.lower() not in {"host", "connection", "content-length"}}
                    target = args.api_forward.rstrip("/") + original.path
                    if original.query:
                        target += "?" + original.query
                    response = context.request.fetch(target, method=request.method, headers=headers,
                                                     data=request.post_data_buffer, timeout=90000,
                                                     fail_on_status_code=False)
                    try:
                        route.fulfill(response=response)
                    finally:
                        response.dispose()
                # Real deployed backend requests use the operator's owned loopback tunnel.
                # All other requests, including UI assets, still use the public HTTPS origin.
                context.route(re.compile(r"^https://con\.coflnet\.com/api/transcription/(?:status|segment)(?:\?|$)"),
                              forward_transcription)
            context.add_init_script(hosted.MEDIA)
            page = context.new_page()
            page.set_default_timeout(90000)
            page.on("pageerror", lambda _: errors.append(True))
            try:
                PHASE = "anonymous app entry and fresh daily quota"
                page.goto(args.origin)
                hosted.semantics(page)
                hosted.click(page, "Ohne Konto fortfahren")
                check_remaining(page, args.initial_remaining)
                result["initial_allowance_verified"] = True
                if args.initial_remaining > 0:
                    PHASE = "server rejects 61-second audio without consuming an allowance"
                    too_long = segment(page, 61)
                    assert too_long["status"] == 413
                    assert too_long["body"]["slug"] == "anonymous_recording_too_long"
                    assert "Sign in" in too_long["body"]["message"]
                    check_remaining(page, args.initial_remaining)
                    result["server_actual_duration_limit"] = True
                english_recording_language(page)
                for number in range(1, args.initial_remaining + 1):
                    record_story(page, number, result)
                    check_remaining(page, args.initial_remaining - number)
                    result["anonymous_daily_allowances_consumed"] = number
                result["remaining_anonymous_stories_transcribed_saved_played"] = args.initial_remaining > 0
                result["server_total_daily_slots_used"] = 3
                PHASE = "fourth recording clear German sign-in guidance before capture"
                open_quick_add(page)
                hosted.field(page, "Was ist hier passiert?", "Geschichte bleibt ohne weitere Aufnahme speicherbar.")
                hosted.click(page, "Aufnahme starten")
                page.wait_for_function("""() => [...document.querySelectorAll('flt-semantics')].some(element => {
                  const text = element.innerText || '';
                  return text.includes('3 täglichen Aufnahmen') && text.includes('melden Sie sich') && text.includes('morgen');
                })""")
                expect(page.get_by_text("Aufnahme beenden", exact=True)).to_have_count(0)
                expect(page.get_by_role("button", name="Geschichte speichern", exact=True)).to_be_enabled()
                page.get_by_role("button", name="Fotos hinzufügen", exact=True).scroll_into_view_if_needed()
                expect(page.get_by_role("button", name="Fotos hinzufügen", exact=True)).to_be_visible()
                result["fourth_recording_guidance_before_capture"] = True
                result["text_and_photo_actions_remain_available"] = True
                PHASE = "server quota rejects fresh UUID and spoofed client IP"
                fourth = segment(page, 1, spoof_ip=True)
                assert fourth["status"] == 429
                assert fourth["body"]["slug"] == "anonymous_daily_limit"
                assert "Sign in" in fourth["body"]["message"] and "tomorrow" in fourth["body"]["message"]
                check_remaining(page, 0)
                result["server_quota_not_bypassed_by_uuid_or_forwarded_header"] = True
                assert not errors, "Uncaught browser errors observed"
                result["uncaught_errors"] = 0
                result["completed"] = True
                print(json.dumps(result), flush=True)
            except Exception:
                if page.url.startswith(args.origin):
                    page.screenshot(path=str(output / 'failure.png'))
                    result['synthetic_textbox_values'] = page.get_by_role('textbox').evaluate_all('nodes => nodes.map(e => e.value)')
                    summary = page.locator('[role]').evaluate_all("nodes => nodes.map(e => ({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),text:(e.innerText||'').slice(0,200),value:e.value}))")
                    (output / 'failure-ui.json').write_text(json.dumps(summary, ensure_ascii=False))
                raise
            finally:
                context.close()
                browser.close()
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", default="https://con.coflnet.com")
    parser.add_argument("--output", required=True)
    parser.add_argument("--audio-fixture", required=True, type=Path, help="Known public lifenizer speech-sample.wav; owner recordings are refused")
    parser.add_argument("--initial-remaining", type=int, choices=range(0, 4), default=3,
                        help="Expected remaining allowance; permits resuming after an interrupted test without resetting production quotas")
    parser.add_argument("--api-forward", help="Optional deployed-backend tunnel, e.g. http://127.0.0.1:18083; isolates test quota from the public IP")
    parser.add_argument("--chromium", default="/usr/bin/chromium")
    parser.add_argument("--browser-arg", action="append", default=[])
    args = parser.parse_args()
    url = urlsplit(args.origin)
    if url.scheme != "https" or url.hostname != "con.coflnet.com" or url.path not in ("", "/") or url.query or url.fragment or url.username:
        parser.error("Use the exact hosted Con HTTPS origin")
    if args.api_forward:
        forwarded = urlsplit(args.api_forward)
        try:
            valid_port = forwarded.port is not None and 1 <= forwarded.port <= 65535
        except ValueError:
            valid_port = False
        if (forwarded.scheme != "http" or forwarded.hostname != "127.0.0.1" or not valid_port
                or forwarded.username is not None or forwarded.password is not None
                or forwarded.path not in ("", "/") or forwarded.query or forwarded.fragment):
            parser.error("--api-forward must be an HTTP loopback origin with an explicit port and no credentials, path, query, or fragment")
    if not args.audio_fixture.is_file():
        parser.error("The synthetic audio fixture must exist")
    os.umask(0o077)
    try:
        run(args)
    except Exception as error:
        # Do not expose browser call logs, raw responses, or typed text.
        print("Anonymous Con E2E failed: " + type(error).__name__ + "; phase=" + PHASE, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
