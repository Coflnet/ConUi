"""Real hosted Con UI checks with two disposable Keycloak identities."""
import argparse
import base64
from contextlib import contextmanager
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import shutil
import shlex
import struct
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import uuid
import wave
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'keycloak'))
from provision import read_fixture
from playwright.sync_api import sync_playwright, expect

expect.set_options(timeout=45000)

PHASE = 'startup'

MEDIA = """(() => {
  window.__e2eMedia = [];
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function(...args) {
    if (!window.__e2eMedia.includes(this)) window.__e2eMedia.push(this);
    return play.apply(this, args);
  };
})();"""


def fake_audio(path):
    with wave.open(str(path), 'wb') as audio:
        audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        audio.writeframes(b''.join(struct.pack('<h', int(4000 * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(16000 * 8)))


def fake_photo(path):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = (b'\x00' + b'\xe8\x55\x32' * 64) * 64
    path.write_bytes(b'\x89PNG\r\n\x1a\n' +
        chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0)) +
        chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))


@contextmanager
def chromium(args, output):
    directory = tempfile.mkdtemp(prefix='con-e2e-browser-')
    try:
        profile = Path(directory) / 'profile'
        audio = args.audio_fixture.resolve() if args.audio_fixture else Path(directory) / 'input.wav'
        if not args.audio_fixture:
            fake_audio(audio)
        command = [args.chromium, '--headless=new', '--disable-extensions', '--no-first-run',
            '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
            '--user-data-dir=' + str(profile), '--lang=de-DE', '--autoplay-policy=no-user-gesture-required',
            '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
            '--use-file-for-fake-audio-capture=' + str(audio), *args.browser_arg, 'about:blank']
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pidfile = output / 'chromium.pid'
        pidfile.write_text(str(process.pid))
        try:
            active = profile / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Chromium startup failed')
                time.sleep(0.1)
            port = int(active.read_text().splitlines()[0])
            yield 'http://127.0.0.1:' + str(port)
        finally:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            if process.poll() is None:
                cmdline = shlex.split(Path(f'/proc/{process.pid}/cmdline').read_text().replace('\0', ' '))
                if '--user-data-dir=' + str(profile) not in cmdline:
                    raise RuntimeError('Browser PID identity changed; refused termination')
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
            pidfile.unlink(missing_ok=True)
    finally:
        # Chromium children can still finish profile writes after its PID exits.
        for attempt in range(50):
            try:
                shutil.rmtree(directory)
                break
            except OSError as error:
                if error.errno != errno.ENOTEMPTY or attempt == 49:
                    raise
                time.sleep(0.1)


def semantics(page):
    page.wait_for_selector('flt-glass-pane', state='attached')
    page.wait_for_function("document.querySelector('flt-semantics-placeholder') || document.querySelector('flt-semantics')")
    page.evaluate("document.querySelector('flt-semantics-placeholder')?.click()")
    page.wait_for_selector('flt-semantics', state='attached')


def click(page, text, *, force=False):
    global PHASE
    PHASE = 'UI control: ' + text
    name = re.compile('^' + re.escape(text) + r'(?: Tab [1-5] von 5)?$')
    target = page.get_by_role('tab', name=text, exact=True).or_(
        page.get_by_role('button', name=name)).or_(
        page.get_by_role('checkbox', name=text, exact=True)).or_(
        page.get_by_role('menuitem', name=text, exact=True)).last
    target.scroll_into_view_if_needed()
    target.click(force=force or target.get_attribute('role') in ('menuitem', 'tab'))


def open_item(page, title):
    global PHASE
    PHASE = 'UI item: ' + title
    page.get_by_role('button', name=re.compile('^' + re.escape(title) + r'(?:\s|$)')).click()


def field(page, label, value):
    global PHASE
    PHASE = 'UI field: ' + label
    # Flutter exposes text inputs through its accessibility tree.
    target = page.get_by_role('textbox', name=re.compile(re.escape(label)))
    target.click()
    expect(target).to_be_focused()
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    target.fill(value)
    expect(target).to_have_value(value)


def settings(page):
    global PHASE
    PHASE = 'UI settings'
    # The app's settings IconButton currently has no accessible label.
    page.mouse.click(page.viewport_size['width'] - 28, 28)
    expect(page.get_by_text('Einstellungen', exact=True)).to_be_visible()


def back(page):
    global PHASE
    PHASE = 'UI back'
    page.get_by_role('button', name=re.compile('Back|Zurück')).first.click(force=True)


def api(page, token, path, method='GET', body=None):
    global PHASE
    PHASE = 'API: ' + method + ' ' + path
    result = page.evaluate("""async ({token,path,method,body}) => {
      const r = await fetch(path, {method, headers: {'Authorization':'Bearer '+token,
        'Content-Type':'application/json'}, body: body === null ? undefined : JSON.stringify(body)});
      return {status:r.status, contentType:r.headers.get('Content-Type'), body:await r.json().catch(()=>null)};
    }""", {'token': token, 'path': path, 'method': method, 'body': body})
    print(f"API check: {method} {path} HTTP {result['status']} ({result['contentType']})", flush=True)
    return result


def login(page, origin, user):
    global PHASE
    PHASE = 'PKCE login: open app'
    captured = {}
    def capture(response):
        if urlsplit(response.url).path == '/api/auth/oidc' and response.status == 200:
            captured['token'] = response.json()['authToken']
    page.on('response', capture)
    try:
        page.goto(origin)
        semantics(page)
        click(page, 'Mit Ihrem Konto anmelden')
        PHASE = 'PKCE login: wait for Keycloak'
        page.wait_for_url('https://app.rfind.de/auth/realms/con/**')
        PHASE = 'PKCE login: submit synthetic identity'
        page.locator('#username').fill(user['username'])
        page.locator('#password').fill(user['password'])
        page.locator('#kc-login').click()
        PHASE = 'PKCE login: consume callback'
        page.wait_for_url(origin.rstrip('/') + '/**')
        semantics(page)
        expect(page.get_by_text('Karte', exact=True).last).to_be_visible()
        if not captured.get('token'):
            raise RuntimeError('Authenticated Con token was not observed')
        result = api(page, captured['token'], '/api/auth/me')
        assert result['status'] == 200 and result['body']['encryptionKeySalt']
        assert urlsplit(page.url).query == '', 'Callback parameters retained'
        return captured['token'], result['body']
    finally:
        page.remove_listener('response', capture)


def screenshots(page, output, name, prepare=None):
    original = dict(page.viewport_size)
    for width, height in ((390, 844), (1440, 900)):
        page.set_viewport_size({'width': width, 'height': height})
        page.wait_for_timeout(300)
        if prepare is not None:
            prepare()
        page.screenshot(path=str(output / f'{name}-{width}.png'))
    page.set_viewport_size(original)


def story(page, title, person, photo):
    # A map tap is the normal quick-add entrypoint.
    page.mouse.click(page.viewport_size['width'] * 0.58, page.viewport_size['height'] * 0.48)
    expect(page.get_by_text('Neue Geschichte', exact=True)).to_be_visible()
    transcription_statuses = []
    def capture_transcription(response):
        if urlsplit(response.url).path == '/api/transcription/segment':
            transcription_statuses.append(response.status)
    page.on('response', capture_transcription)
    click(page, 'Aufnahme starten')
    expect(page.get_by_text('Aufnahme beenden', exact=True)).to_be_visible()
    page.wait_for_timeout(3000)
    click(page, 'Aufnahme beenden')
    expect(page.get_by_role('button', name='Geschichte speichern', exact=True)).to_be_enabled()
    page.remove_listener('response', capture_transcription)
    assert transcription_statuses and all(status == 200 for status in transcription_statuses), 'Authenticated transcription did not succeed'
    field(page, 'Was ist hier passiert?', 'Synthetische Erzählung für die Bereitstellungsprüfung.')
    field(page, 'Namen eingeben', person)
    click(page, '„' + person + '“ hinzufügen')
    field(page, 'Titel (optional)', title)
    with page.expect_file_chooser() as chooser:
        click(page, 'Fotos hinzufügen')
    chooser.value.set_files(photo)
    expect(page.get_by_role('button', name=photo.name, exact=True)).to_be_visible()
    screenshots(page, photo.parent, 'quick-add-photo')
    click(page, 'Geschichte speichern')
    click(page, 'Geschichten')
    calendar(page, photo.parent)
    open_item(page, title)
    photo_view(page, photo.name, photo.parent)
    screenshots(page, photo.parent, 'story-details')
    expect(page.get_by_role('button', name=re.compile(re.escape(person) + '$'))).to_be_visible()
    playback(page)
    click(page, 'Verbindung hinzufügen', force=True)
    page.get_by_role('button', name=re.compile('Verbinden mit')).click()
    click(page, '+ Neue Person hinzufügen…')
    field(page, 'Name der neuen Person', person + ' Freundin')
    click(page, 'Hinzufügen')
    expect(page.get_by_role('button', name=re.compile(re.escape(person + ' Freundin'))).first).to_be_visible()


def calendar(page, output=None):
    global PHASE
    PHASE = 'UI calendar year navigation'
    year = page.evaluate('new Date().getFullYear()')
    month = page.evaluate("new Intl.DateTimeFormat('de-DE', {month:'long'}).format(new Date())")
    expect(page.get_by_text(f'{month} {year}', exact=True)).to_be_visible()
    expect(page.get_by_role('button', name=re.compile(f'^{year} · Jahre\\s+1 Geschichte$'))).to_be_visible()
    click(page, 'Vorheriges Jahr')
    expect(page.get_by_text(f'{month} {year - 1}', exact=True)).to_be_visible()
    expect(page.get_by_role('button', name=re.compile(f'^{year - 1} · Jahre\\s+0 Geschichten$'))).to_be_visible()
    click(page, 'Nächstes Jahr')
    expect(page.get_by_text(f'{month} {year}', exact=True)).to_be_visible()
    page.get_by_role('button', name=re.compile(f'^{year} · Jahre')).click()
    row = page.get_by_role('button', name=re.compile(f'^{year}\\s+1 Geschichte$'))
    expect(row).to_be_visible()
    if output is not None:
        def show_years():
            if row.count() == 0:
                page.get_by_role('button', name=re.compile(f'^{year} · Jahre')).click()
            expect(row).to_be_visible()
        screenshots(page, output, 'calendar-years', show_years)
        show_years()
    row.click()
    expect(page.get_by_text(f'{month} {year}', exact=True)).to_be_visible()


def photo_view(page, filename, output=None):
    global PHASE
    PHASE = 'UI original photo viewer: open'
    page.get_by_role('button', name=re.compile('^' + re.escape(filename) + r'(?:\s|$)')).click(force=True)
    PHASE = 'UI original photo viewer: title'
    expect(page.get_by_text(filename, exact=True).last).to_be_visible()
    if output is not None:
        PHASE = 'UI original photo viewer: screenshots'
        screenshots(page, output, 'photo-original')
    PHASE = 'UI original photo viewer: loaded'
    expect(page.get_by_role('progressbar')).to_have_count(0)
    expect(page.get_by_text(re.compile('Dieses Foto ist auf diesem Gerät nicht verfügbar'))).to_have_count(0)
    PHASE = 'UI original photo viewer: return'
    back(page)


def playback(page):
    click(page, 'Abspielen', force=True)
    page.wait_for_function("window.__e2eMedia.some(e => !e.paused && e.currentTime > 0.2)")
    assert page.evaluate('window.__e2eMedia.filter(e => !e.paused).every(e => !e.error)')
    click(page, 'Pause', force=True)


def backup(page, output, photo):
    global PHASE
    back(page)
    settings(page)
    open_item(page, 'Sicherung erstellen')
    expect(page.get_by_text(re.compile('1 Aufnahme'))).to_be_visible()
    with page.expect_download() as download:
        click(page, 'Sicherung erstellen')
    path = output / 'synthetic-backup.zip'
    download.value.save_as(path)
    PHASE = 'Backup original photo and recording integrity'
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        assert manifest['formatVersion'] == 1 and not manifest['missingAudio']
        data = json.loads(archive.read('data.json'))
        photo_row, = [row['data'] for row in data['files'] if row['data']['file_name'] == photo.name]
        original = photo.read_bytes()
        digest = hashlib.sha256(original).hexdigest()
        assert base64.b64decode(photo_row['bytes'], validate=True) == original
        assert photo_row['size'] == len(original) and photo_row['sha256'] == digest
        story_row, = data['events']
        attachment, = [file for file in story_row['data']['files'] if file['id'] == photo_row['id']]
        assert attachment['fileName'] == photo.name and attachment['sha256'] == digest
        recording, = manifest['recordings']
        wav = archive.read('recordings/' + recording['id'] + '.wav')
        assert len(wav) == recording['size'] and hashlib.sha256(wav).hexdigest() == recording['sha256']
        assert wav[:4] == b'RIFF' and wav[8:12] == b'WAVE' and struct.unpack_from('<I', wav, 4)[0] == len(wav) - 8
    expect(page.get_by_text('Sicherung erstellt', exact=True)).to_be_visible()
    click(page, 'Fertig')
    expect(page.get_by_text('Einstellungen', exact=True)).to_be_visible()
    return path


def run(args):
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    photo = output / 'synthetic-photo.png'
    fake_photo(photo)
    users = read_fixture(args.fixture)['users']
    assert len(users) == 2
    result = {'completed': False, 'cloud_sync': 'not_verified_s3_unconfigured'}
    with chromium(args, output) as endpoint, sync_playwright() as playwright:
        browser = playwright.chromium.connect_over_cdp(endpoint)
        def context(width):
            ctx = browser.new_context(viewport={'width': width, 'height': 900 if width > 500 else 844},
                locale='de-DE', permissions=['microphone'], accept_downloads=True)
            ctx.add_init_script(MEDIA)
            return ctx
        first, second, restored = context(1440), context(390), context(1440)
        errors = []
        pages = [ctx.new_page() for ctx in (first, second, restored)]
        for page in pages:
            page.set_default_timeout(45000)
            page.on('pageerror', lambda _: errors.append(True))
        try:
            page, other, restore = pages
            print('Checking desktop/mobile public PKCE and account isolation', flush=True)
            token, account = login(page, args.origin, users[0])
            result['desktop_pkce'] = True
            other_token, other_account = login(other, args.origin, users[1])
            assert account['id'] != other_account['id'] and account['encryptionKeySalt'] != other_account['encryptionKeySalt']
            device_id = 'con-e2e-' + str(uuid.uuid4())
            registered = api(page, token, '/api/sync/device', 'POST', {'deviceId':device_id,'deviceName':'Synthetic E2E','platform':'web'})
            assert registered['status'] == 200
            own = api(page, token, '/api/sync/devices')
            foreign = api(other, other_token, '/api/sync/devices')
            assert own['status'] == foreign['status'] == 200
            assert any(d['deviceId'] == device_id for d in own['body'])
            assert all(d['deviceId'] != device_id for d in foreign['body'])
            result['mobile_pkce_account_isolation'] = True
            upload = api(page, token, '/api/sync/upload', 'POST', {'blobType':'person','blobId':str(uuid.uuid4()),'checksum':'0'*64,'expectedVersion':0})
            assert upload['status'] == 503 and upload['body']['slug'] == 'storage_unavailable'
            result['s3_expected_503'] = True
            click(page, 'Jetzt abgleichen')
            page.wait_for_function("message => [...document.querySelectorAll('flt-semantics')].some(e => (e.innerText || '').includes(message))", arg='Geben Sie vor dem Abgleich Ihr Verschlüsselungspasswort ein.')
            result['sync_encryption_locked'] = True
            title, person = 'E2E Geschichte', 'E2E Erzählerin'
            print('Checking story, recording playback and relationship UI', flush=True)
            story(page, title, person, photo)
            result['story_photo_original_view'] = True
            result['calendar_year_counts_navigation'] = True
            result['story_recording_relationship_playback'] = True
            result['authenticated_transcription_succeeded'] = True
            print('Checking backup, reload and fresh-profile restore', flush=True)
            archive = backup(page, output, photo)
            result['backup_photo_original_sha256'] = hashlib.sha256(photo.read_bytes()).hexdigest()
            back(page)
            page.reload()
            semantics(page)
            same = api(page, token, '/api/auth/me')
            assert same['status'] == 200 and same['body']['id'] == account['id'] and same['body']['encryptionKeySalt'] == account['encryptionKeySalt']
            click(page, 'Geschichten')
            open_item(page, title)
            photo_view(page, photo.name)
            playback(page)
            result['reload_preserved_photo'] = True
            result['reload_preserved_account_recording'] = True
            restore.goto(args.origin)
            semantics(restore)
            click(restore, 'Ohne Konto fortfahren')
            settings(restore)
            with restore.expect_file_chooser() as chooser:
                open_item(restore, 'Aus Sicherung wiederherstellen')
            chooser.value.set_files(archive)
            click(restore, 'Wiederherstellen')
            expect(restore.get_by_text('Wiederherstellung abgeschlossen', exact=True)).to_be_visible()
            click(restore, 'Fertig')
            expect(restore.get_by_text('Karte', exact=True).last).to_be_visible()
            click(restore, 'Geschichten')
            calendar(restore)
            open_item(restore, title)
            photo_view(restore, photo.name)
            playback(restore)
            result['fresh_profile_restore_photo'] = True
            expect(restore.get_by_role('button', name=re.compile(re.escape(person) + '$'))).to_be_visible()
            expect(restore.get_by_role('button', name=re.compile(re.escape(person + ' Freundin'))).first).to_be_visible()
            result['fresh_profile_restore_playback_relationship'] = True
            assert not errors, 'Uncaught browser errors observed'
            result['uncaught_errors'] = 0
            result['completed'] = True
            print(json.dumps(result))
        except Exception:
            for index, failed in enumerate(pages):
                if failed.url.startswith(args.origin):
                    failed.screenshot(path=str(output / f'failure-{index}.png'))
                    summary = failed.locator('[role]').evaluate_all("nodes => nodes.map(e => ({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),text:(e.innerText||'').slice(0,200)}))")
                    (output / f'failure-ui-{index}.json').write_text(json.dumps(summary, ensure_ascii=False))
            raise
        finally:
            (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            for ctx in (first, second, restored):
                ctx.close()
            browser.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', required=True)
    parser.add_argument('--origin', default='https://con.coflnet.com')
    parser.add_argument('--output', required=True)
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    parser.add_argument('--audio-fixture', type=Path, help='Optional WAV file for Chromium fake microphone capture')
    args = parser.parse_args()
    url = urlsplit(args.origin)
    if url.scheme != 'https' or url.hostname != 'con.coflnet.com' or url.path not in ('', '/') or url.query or url.fragment or url.username:
        parser.error('Use the exact hosted Con HTTPS origin')
    if args.audio_fixture and not args.audio_fixture.is_file():
        parser.error('The audio fixture must be an existing WAV file')
    os.umask(0o077)
    try:
        run(args)
    except Exception as error:
        # Playwright exceptions include input values and redirect URLs. Never print them.
        print('Hosted Con E2E failed: ' + type(error).__name__ + '; phase=' + PHASE, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
