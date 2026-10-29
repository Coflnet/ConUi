"""Isolated recording wake-lock lifecycle checks using Chromium's real API."""
import argparse
import json
import os
from pathlib import Path
import re

import hosted
import people
from playwright.sync_api import sync_playwright, expect


INSTRUMENT = """(() => {
  const state = window.__wake = {requests: 0, granted: 0, released: 0, denied: 0};
  const request = navigator.wakeLock.request.bind(navigator.wakeLock);
  navigator.wakeLock.request = async (...args) => {
    state.requests++;
    if (MODE === 'denied') {
      state.denied++;
      throw new DOMException('Synthetic policy denial', 'NotAllowedError');
    }
    let sentinel;
    try { sentinel = await request(...args); }
    catch (error) { state.error = error.name + ': ' + error.message; throw error; }
    state.granted++;
    sentinel.addEventListener('release', () => state.released++);
    if (MODE === 'pending') await new Promise(resolve => window.__resolveWake = resolve);
    return sentinel;
  };
})();"""


def run(args):
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    result = {'completed': False, 'origin': args.origin, 'cases': {},
              'limitation': 'Headless API checks cannot prove physical screen idle behavior.'}
    with people.local_server(args, output), hosted.chromium(args, output) as endpoint, sync_playwright() as pw:
        browser = pw.chromium.connect_over_cdp(endpoint)
        try:
            for mode in ('real', 'denied', 'pending'):
                context = browser.new_context(viewport={'width': 1440, 'height': 900},
                                              locale='de-DE', permissions=['microphone', 'screen-wake-lock'],
                                              service_workers='block')
                errors, intercepted = [], []
                page = context.new_page()
                page.set_default_timeout(45000)
                page.on('pageerror', lambda error: errors.append(str(error)[:300]))
                context.add_init_script(INSTRUMENT.replace('MODE', json.dumps(mode)))
                context.add_init_script(hosted.MEDIA)
                if args.serve_directory:
                    def renderer(route):
                        asset = args.serve_directory / 'canvaskit' / Path(*route.request.url.split('/')[5:])
                        route.fulfill(path=asset, headers={'Access-Control-Allow-Origin': '*'})
                    context.route(re.compile(r'^https://www\.gstatic\.com/flutter-canvaskit/[a-f0-9]+/(?:chromium/)?canvaskit\.(?:js|wasm)(?:\?.*)?$'), renderer)

                def transcription(route):
                    intercepted.append(route.request.method + ' ' + route.request.url.split('?')[0].split('/api/')[1])
                    route.fulfill(json={'available': True, 'text': 'Synthetische Aufnahme.',
                                        'usedSeconds': 0, 'remainingSeconds': 3600,
                                        'dailyLimitSeconds': 3600, 'resetAt': '2099-01-01T00:00:00Z'})
                context.route(re.compile(r'/api/transcription/(status|segment)(?:\?|$)'), transcription)
                try:
                    people.guest(page, args.origin)
                    people.quick_add(page)
                    assert page.evaluate('window.__wake.requests') == 0
                    hosted.click(page, 'Aufnahme starten')
                    stop = page.get_by_role('button', name=re.compile('^Aufnahme beenden'))
                    expect(stop).to_be_visible()
                    page.wait_for_function('window.__wake.requests === 1')
                    if mode == 'denied':
                        page.wait_for_function('window.__wake.denied === 1')
                    else:
                        page.wait_for_function('window.__wake.granted === 1 || window.__wake.error')
                        assert page.evaluate('window.__wake.granted') == 1, page.evaluate('window.__wake')
                        assert page.evaluate('window.__wake.released') == 0
                    # Exercise capture before stop; short captures can have no WAV segment.
                    page.wait_for_timeout(1500)
                    assert page.evaluate('window.__wake.released') == 0
                    if mode == 'real':
                        page.screenshot(path=str(output / 'recording-awake.png'))
                    stop.click()
                    expect(page.get_by_role('button', name='Geschichte speichern', exact=True)).to_be_enabled()
                    if mode == 'pending':
                        assert page.evaluate('window.__wake.released') == 0
                        page.evaluate('window.__resolveWake()')
                    if mode != 'denied':
                        page.wait_for_function('window.__wake.released === 1')
                    before = page.evaluate('({...window.__wake})')
                    page.evaluate("""() => {
                      document.dispatchEvent(new Event('visibilitychange'));
                      document.dispatchEvent(new Event('fullscreenchange'));
                    }""")
                    page.wait_for_timeout(500)
                    assert page.evaluate('({...window.__wake})') == before
                    if mode == 'denied':
                        hosted.field(page, 'Titel (optional)', 'E2E verweigerter Bildschirmschutz')
                        hosted.click(page, 'Geschichte speichern')
                        hosted.click(page, 'Geschichten')
                        hosted.open_item(page, 'E2E verweigerter Bildschirmschutz')
                        hosted.playback(page)
                    assert not errors, errors
                    result['cases'][mode] = {**before, 'stop_usable': True,
                                             'no_reacquire_after_stop': True,
                                             'transcription_fixtures': intercepted}
                    if mode == 'denied':
                        result['cases'][mode]['recorded_audio_playback'] = True
                except Exception:
                    page.screenshot(path=str(output / f'failure-{mode}.png'))
                    result['failed_case'] = mode
                    result['wake_state'] = page.evaluate('window.__wake || null')
                    result['uncaught_errors'] = errors
                    raise
                finally:
                    context.close()
            result['completed'] = True
        finally:
            (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            browser.close()
    print(json.dumps(result), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='http://127.0.0.1:18085')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--serve-directory', type=Path)
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    args = parser.parse_args()
    args.audio_fixture = None
    args.origin = args.origin.rstrip('/')
    if args.origin not in ('http://127.0.0.1:18085', 'https://con.coflnet.com'):
        parser.error('Use the exact localhost port 18085 or hosted Con HTTPS origin')
    if args.serve_directory and (args.origin.startswith('https:') or not (args.serve_directory / 'index.html').is_file()):
        parser.error('Local serving requires a web build and localhost origin')
    os.umask(0o077)
    run(args)


if __name__ == '__main__':
    main()
