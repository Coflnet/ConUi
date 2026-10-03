"""Synthetic person recognition checks against a local build or hosted Con."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from urllib.request import build_opener, ProxyHandler
from urllib.parse import urlsplit
import wave
import zipfile

import hosted
from playwright.sync_api import sync_playwright, expect

PHASE = 'startup'
TITLES = ['E2E Personen Deutsch', 'E2E Personen English']
GERMAN = 'Meine Schwester Jane Smith besuchte meinen Onkel Paul und meine Tante Eva.'
ENGLISH = 'My sister Jane Smith visited my uncle Paul.'


@contextmanager
def local_server(args, output):
    if not args.serve_directory:
        yield
        return
    directory = args.serve_directory.resolve()
    command = [sys.executable, '-m', 'http.server', '18085', '--bind',
               '127.0.0.1', '--directory', str(directory)]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pidfile = output / 'http-server.pid'
    pidfile.write_text(str(process.pid))
    try:
        http = build_opener(ProxyHandler({}))
        deadline = time.monotonic() + 10
        while True:
            if process.poll() is not None:
                raise RuntimeError('Owned local HTTP server did not start')
            try:
                with http.open(args.origin + '/index.html', timeout=1) as response:
                    assert response.status == 200
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError('Owned local HTTP server did not become ready')
                time.sleep(.1)
        yield
    finally:
        if process.poll() is None:
            actual = Path(f'/proc/{process.pid}/cmdline').read_bytes().split(b'\0')
            if [part.decode() for part in actual if part] != command:
                raise RuntimeError('HTTP server PID identity changed; refused termination')
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        pidfile.unlink(missing_ok=True)


def guest(page, origin):
    page.goto(origin)
    hosted.semantics(page)
    hosted.click(page, 'Ohne Konto fortfahren')
    expect(page.get_by_text('Karte', exact=True).last).to_be_visible()


def quick_add(page):
    hosted.click(page, 'Geschichte hinzufügen')
    expect(page.get_by_text('Neue Geschichte', exact=True)).to_be_visible()


def chip(page, name):
    return page.get_by_role('checkbox', name=name, exact=True)


def details(page, title, names, recorded=False):
    hosted.open_item(page, title)
    for name in names:
        expect(page.get_by_role('button', name=re.compile(re.escape(name) + '$'))).to_be_visible()
    if recorded:
        hosted.playback(page)


def export(page, output, filename):
    hosted.settings(page)
    hosted.open_item(page, 'Sicherung erstellen')
    with page.expect_download() as download:
        hosted.click(page, 'Sicherung erstellen')
    archive = output / filename
    download.value.save_as(archive)
    expect(page.get_by_text('Sicherung erstellt', exact=True)).to_be_visible()
    hosted.click(page, 'Fertig')
    hosted.back(page)
    return archive


def check_archive(archive, recorded):
    with zipfile.ZipFile(archive) as bundle:
        data = json.loads(bundle.read('data.json'))
        people = [row['data'] for row in data['persons']]
        names = {person['name']: person['id'] for person in people}
        expected = {'Jane Smith', 'Paul'} | ({'Anna Miller'} if recorded else set())
        assert len(people) == len(expected) and set(names) == expected
        stories = {row['data']['title']: row['data'] for row in data['events']}
        assert set(stories) == set(TITLES)
        first, second = [stories[title] for title in TITLES]
        common = {names['Jane Smith'], names['Paul']}
        assert set(first['participantIds']) == common
        assert set(second['participantIds']) == {names[name] for name in expected}
        assert first['description'] == GERMAN and not first['files']
        if recorded:
            assert second['description'].startswith('Synthetische Notiz bleibt erhalten.')
            manifest = json.loads(bundle.read('manifest.json'))
            assert not manifest['missingAudio']
            recording, = manifest['recordings']
            attachment, = second['files']
            assert attachment['id'] == recording['id'] and attachment['kind'] == 'recording'
            wav = bundle.read('recordings/' + recording['id'] + '.wav')
            assert len(wav) == recording['size'] and hashlib.sha256(wav).hexdigest() == recording['sha256']
        else:
            assert second['description'] == ENGLISH and not second['files']
        return names


def run(args):
    global PHASE
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    recorded = args.audio_fixture is not None
    result = {'completed': False, 'recorded': recorded, 'origin': args.origin}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    with local_server(args, output), hosted.chromium(args, output) as endpoint, sync_playwright() as playwright:
        browser = playwright.chromium.connect_over_cdp(endpoint)
        contexts = [browser.new_context(viewport={'width': 1440, 'height': 900},
                    locale='de-DE', permissions=['microphone'], accept_downloads=True) for _ in range(2)]
        pages = []
        errors = []
        for context in contexts:
            if args.serve_directory:
                # Use the build's exact renderer bytes instead of a flaky CDN.
                def renderer(route):
                    parts = urlsplit(route.request.url).path.split('/')[3:]
                    asset = args.serve_directory / 'canvaskit' / Path(*parts)
                    route.fulfill(path=asset, headers={'Access-Control-Allow-Origin': '*'})
                context.route(re.compile(r'^https://www\.gstatic\.com/flutter-canvaskit/[a-f0-9]+/(?:chromium/)?canvaskit\.(?:js|wasm)(?:\?.*)?$'), renderer)
            context.add_init_script(hosted.MEDIA)
            page = context.new_page()
            page.set_default_timeout(45000)
            page.on('pageerror', lambda _: errors.append(True))
            pages.append(page)
        page, restore = pages
        try:
            PHASE = 'open isolated synthetic account or local guest'
            if args.fixture:
                hosted.login(page, args.origin, hosted.read_fixture(args.fixture)['users'][0])
            else:
                guest(page, args.origin)
            PHASE = 'German draft automatically recognizes three people'
            quick_add(page)
            hosted.field(page, 'Was ist hier passiert?', GERMAN)
            hosted.field(page, 'Titel (optional)', TITLES[0])
            for name in ('Jane Smith', 'Paul', 'Eva'):
                expect(chip(page, name)).to_be_visible()
            expect(page.get_by_role('textbox', name='Namen eingeben')).to_have_value('')
            hosted.screenshots(page, output, 'people-draft')
            PHASE = 'remove Eva from automatic participants'
            chip(page, 'Eva').get_by_role('button', name='Löschen').click()
            expect(chip(page, 'Eva')).to_have_count(0)
            hosted.click(page, 'Geschichte speichern')
            hosted.click(page, 'Geschichten')
            details(page, TITLES[0], ('Jane Smith', 'Paul'))
            hosted.back(page)
            hosted.click(page, 'Karte')
            if recorded:
                hosted.settings(page)
                hosted.open_item(page, 'Sprache der Aufnahmen')
                page.get_by_role('radio', name='English', exact=True).click()
                expect(page.get_by_text('Einstellungen', exact=True)).to_be_visible()
                hosted.back(page)
            PHASE = 'second story reuses both existing people'
            quick_add(page)
            hosted.field(page, 'Titel (optional)', TITLES[1])
            if recorded:
                notes = 'Synthetische Notiz bleibt erhalten.'
                hosted.field(page, 'Was ist hier passiert?', notes)
                statuses = []
                def capture(response):
                    if urlsplit(response.url).path == '/api/transcription/segment':
                        statuses.append(response.status)
                page.on('response', capture)
                hosted.click(page, 'Aufnahme starten')
                expect(page.get_by_text('Aufnahme beenden', exact=True)).to_be_visible()
                with wave.open(str(args.audio_fixture)) as audio:
                    duration = audio.getnframes() / audio.getframerate()
                page.wait_for_timeout(int((duration + 1) * 1000))
                hosted.click(page, 'Aufnahme beenden')
                expect(page.get_by_role('button', name='Geschichte speichern', exact=True)).to_be_enabled(timeout=90000)
                transcript = page.get_by_role('textbox', name=re.compile(r'Was ist hier passiert\?'))
                transcript.click()
                expect(transcript).to_be_focused()
                expect(transcript).to_have_value(re.compile(r'Anna Miller', re.I), timeout=90000)
                assert transcript.input_value().startswith(notes)
                page.remove_listener('response', capture)
                assert statuses and all(status == 200 for status in statuses)
                result['transcription_http_statuses'] = statuses
            else:
                hosted.field(page, 'Was ist hier passiert?', ENGLISH)
            expected = ['Jane Smith', 'Paul'] + (['Anna Miller'] if recorded else [])
            for name in expected:
                expect(chip(page, name)).to_be_visible()
            expect(page.get_by_role('textbox', name='Namen eingeben')).to_have_value('')
            hosted.screenshots(page, output, 'people-reused')
            hosted.click(page, 'Geschichte speichern')
            hosted.click(page, 'Geschichten')
            details(page, TITLES[1], expected, recorded)
            hosted.screenshots(page, output, 'people-story')
            hosted.back(page)
            PHASE = 'ZIP proves reused person IDs and absence of Eva'
            archive = export(page, output, 'people-backup.zip')
            names = check_archive(archive, recorded)
            result['person_count'] = len(names)
            result['backup_exact_people_and_reused_ids'] = True
            PHASE = 'reload preserves linked story participants'
            page.reload()
            hosted.semantics(page)
            hosted.click(page, 'Geschichten')
            details(page, TITLES[1], expected, recorded)
            result['reload_preserved_participants'] = True
            PHASE = 'fresh browser context restores linked story participants'
            guest(restore, args.origin)
            hosted.settings(restore)
            with restore.expect_file_chooser() as chooser:
                hosted.open_item(restore, 'Aus Sicherung wiederherstellen')
            chooser.value.set_files(archive)
            hosted.click(restore, 'Wiederherstellen')
            expect(restore.get_by_text('Wiederherstellung abgeschlossen', exact=True)).to_be_visible()
            hosted.click(restore, 'Fertig')
            hosted.click(restore, 'Geschichten')
            details(restore, TITLES[0], ('Jane Smith', 'Paul'))
            hosted.back(restore)
            details(restore, TITLES[1], expected, recorded)
            hosted.screenshots(restore, output, 'people-restored')
            hosted.back(restore)
            restored = export(restore, output, 'people-restored-backup.zip')
            assert check_archive(restored, recorded) == names
            result['fresh_restore_preserved_exact_ids'] = True
            result['recording_playback_reload_restore'] = recorded
            assert not errors
            result['uncaught_errors'] = 0
            result['completed'] = True
            print(json.dumps(result), flush=True)
        except Exception:
            for index, failed in enumerate(pages):
                if failed.url.startswith(args.origin):
                    failed.screenshot(path=str(output / f'failure-{index}.png'))
                    summary = failed.locator('[role]').evaluate_all("nodes => nodes.map(e => ({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),text:(e.innerText||'').slice(0,200)}))")
                    (output / f'failure-ui-{index}.json').write_text(json.dumps(summary, ensure_ascii=False))
            raise
        finally:
            result['uncaught_errors'] = len(errors)
            (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            for context in contexts:
                context.close()
            browser.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='http://127.0.0.1:18085')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--serve-directory', type=Path, help='Serve a built Flutter web directory on owned localhost port 18085')
    parser.add_argument('--fixture', help='Protected disposable Keycloak fixture; public hosted origin only')
    parser.add_argument('--audio-fixture', type=Path, help='Fictional people-speech.wav for real hosted ASR, requiring --fixture')
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    args = parser.parse_args()
    args.origin = args.origin.rstrip('/')
    if args.origin not in ('http://127.0.0.1:18085', 'http://localhost:18085', 'https://con.coflnet.com'):
        parser.error('Use exact localhost port 18085 or hosted Con HTTPS origin')
    if args.serve_directory and (args.origin.startswith('https:') or not (args.serve_directory / 'index.html').is_file()):
        parser.error('Local serving requires an existing web build and localhost origin')
    if args.fixture and args.origin != 'https://con.coflnet.com':
        parser.error('Identity fixtures are accepted only for hosted Con')
    if args.audio_fixture and (not args.fixture or not args.audio_fixture.is_file()):
        parser.error('Real speech verification requires a hosted fixture and an existing fictional WAV')
    os.umask(0o077)
    try:
        run(args)
    except Exception as error:
        print('Con people E2E failed: ' + type(error).__name__ + '; phase=' + PHASE + '; control=' + hosted.PHASE, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
