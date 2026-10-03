"""Real hosted Con UI checks with two disposable Keycloak identities."""
import argparse
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


@contextmanager
def chromium(args, output):
    directory = tempfile.mkdtemp(prefix='con-e2e-browser-')
    try:
        profile = Path(directory) / 'profile'
        audio = Path(directory) / 'input.wav'
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
    target = page.get_by_role('button', name=name).or_(
        page.get_by_role('checkbox', name=text, exact=True)).or_(
        page.get_by_role('menuitem', name=text, exact=True)).or_(
        page.get_by_text(text, exact=True)).last
    target.scroll_into_view_if_needed()
    target.click(force=force)


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
    target.press('Control+A')
    target.press_sequentially(value)


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


def story(page, title, person):
    # A map tap is the normal quick-add entrypoint.
    page.mouse.click(page.viewport_size['width'] * 0.58, page.viewport_size['height'] * 0.48)
    expect(page.get_by_text('Neue Geschichte', exact=True)).to_be_visible()
    click(page, 'Aufnahme starten')
    expect(page.get_by_text('Aufnahme beenden', exact=True)).to_be_visible()
    page.wait_for_timeout(3000)
    click(page, 'Aufnahme beenden')
    expect(page.get_by_role('button', name='Aufnahme als Text', exact=True)).to_be_visible()
    field(page, 'Was ist hier passiert?', 'Synthetische Erzählung für die Bereitstellungsprüfung.')
    field(page, 'Namen eingeben', person)
    click(page, '„' + person + '“ hinzufügen')
    field(page, 'Titel (optional)', title)
    click(page, 'Geschichte speichern')
    click(page, 'Geschichten')
    open_item(page, title)
    expect(page.get_by_role('button', name=re.compile(re.escape(person) + '$'))).to_be_visible()
    playback(page)
    click(page, 'Verbindung hinzufügen', force=True)
    page.get_by_role('button', name=re.compile('Verbinden mit')).click()
    click(page, '+ Neue Person hinzufügen…')
    field(page, 'Name der neuen Person', person + ' Freundin')
    click(page, 'Hinzufügen')
    expect(page.get_by_role('button', name=re.compile(re.escape(person + ' Freundin'))).first).to_be_visible()


def playback(page):
    click(page, 'Abspielen', force=True)
    page.wait_for_function("window.__e2eMedia.some(e => !e.paused && e.currentTime > 0.2)")
    assert page.evaluate('window.__e2eMedia.every(e => !e.error)')
    click(page, 'Pause', force=True)


def backup(page, output):
    back(page)
    settings(page)
    open_item(page, 'Sicherung erstellen')
    expect(page.get_by_text(re.compile('1 Aufnahme'))).to_be_visible()
    with page.expect_download() as download:
        click(page, 'Sicherung erstellen')
    path = output / 'synthetic-backup.zip'
    download.value.save_as(path)
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        assert manifest['formatVersion'] == 1 and not manifest['missingAudio']
        recording, = manifest['recordings']
        wav = archive.read('recordings/' + recording['id'] + '.wav')
        assert len(wav) == recording['size'] and hashlib.sha256(wav).hexdigest() == recording['sha256']
        assert wav[:4] == b'RIFF' and wav[8:12] == b'WAVE' and struct.unpack_from('<I', wav, 4)[0] == len(wav) - 8
    expect(page.get_by_text('Sicherung erstellt', exact=True)).to_be_visible()
    click(page, 'Fertig')
    return path


def run(args):
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
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
            story(page, title, person)
            result['story_recording_relationship_playback'] = True
            print('Checking backup, reload and fresh-profile restore', flush=True)
            archive = backup(page, output)
            back(page)
            page.reload()
            semantics(page)
            same = api(page, token, '/api/auth/me')
            assert same['status'] == 200 and same['body']['id'] == account['id'] and same['body']['encryptionKeySalt'] == account['encryptionKeySalt']
            click(page, 'Geschichten')
            open_item(page, title)
            playback(page)
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
            back(restore)
            click(restore, 'Geschichten')
            open_item(restore, title)
            playback(restore)
            expect(restore.get_by_role('button', name=re.compile(re.escape(person) + '$'))).to_be_visible()
            expect(restore.get_by_role('button', name=re.compile(re.escape(person + ' Freundin'))).first).to_be_visible()
            result['fresh_profile_restore_playback_relationship'] = True
            assert not errors, 'Uncaught browser errors observed'
            result['uncaught_errors'] = 0
            result['completed'] = True
            print(json.dumps(result))
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
    args = parser.parse_args()
    url = urlsplit(args.origin)
    if url.scheme != 'https' or url.hostname != 'con.coflnet.com' or url.path not in ('', '/') or url.query or url.fragment or url.username:
        parser.error('Use the exact hosted Con HTTPS origin')
    os.umask(0o077)
    try:
        run(args)
    except Exception as error:
        # Playwright exceptions include input values and redirect URLs. Never print them.
        print('Hosted Con E2E failed: ' + type(error).__name__ + '; phase=' + PHASE, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
