"""Verify consented reports through the real UI using the pinned synthetic backup."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile

import connections
import hosted
import people
from playwright.sync_api import sync_playwright, expect

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'training'))
import export as training_export

PHASE = 'startup'
BACKUP_SHA256 = 'e4d6525487619a69d2932d35256407d8149df3e22a72eedba5f4dd5fc1dccd83'
CORRECTION = 'Paul works at Google; James and Paul are siblings.'
REPORT = 'Trainingsbeispiel melden'
AUDIO = 'Ausgewählte Original-WAV einschließen (höchstens 10 MiB)'
CONSENT = ('Ich stimme zu, dass das ausgewählte Audio (falls eingeschlossen), der Geschichtentext, '
           'Namen, Beziehungen und die Korrektur für das Training auf den Server hochgeladen '
           'und autorisierten Prüfern zugänglich gemacht werden.')


def fixture(path):
    if hashlib.sha256(path.read_bytes()).hexdigest() != BACKUP_SHA256:
        raise RuntimeError('Refused backup outside the pinned synthetic speech fixture')
    data = connections.archive_data(path, recorded=True)
    story, = (row for row in data['events'] if row['title'] == connections.TITLE)
    recording, = story['files']
    with zipfile.ZipFile(path) as bundle:
        audio = bundle.read('recordings/' + recording['id'] + '.wav')
    facts = {row['name']: [fact for fact in row['storyFacts'].get(story['id'], '').split('\n') if fact.strip()]
             for row in data['persons']}
    return story['description'], audio, facts


def status(client, path, method='GET', reviewer=True, extra_headers=None):
    headers = {'User-Agent': 'ConTrainingExport/1.0'}
    if reviewer:
        headers['X-Training-Token'] = client.token
    headers.update(extra_headers or {})
    request = urllib.request.Request(client.base_url + path, headers=headers, method=method)
    try:
        with client.opener.open(request, timeout=30) as response:
            return response.status
    except urllib.error.HTTPError as error:
        error.close()
        return error.code


def cleanup(client, owned, result):
    success = True
    for receipt in owned:
        path = f"/api/training-samples/{receipt['date']}/{receipt['id']}"
        try:
            deleted = status(client, path, method='DELETE')
            result['delete_http_statuses'].append(deleted)
            absent = status(client, path + '/audio')
            result['deleted_audio_http_statuses'].append(absent)
            success = success and deleted == 204 and absent == 404
        except Exception:
            success = False
    for day in {receipt['date'] for receipt in owned}:
        cursor = None
        cursors = set()
        expected_absent = {receipt['id'] for receipt in owned if receipt['date'] == day}
        try:
            for _ in range(training_export.MAX_PAGES):
                items, cursor = client.page(day, cursor)
                if expected_absent.intersection(item['id'] for item in items):
                    success = False
                if cursor is None:
                    break
                if cursor in cursors:
                    raise RuntimeError('Repeated cleanup verification cursor')
                cursors.add(cursor)
            else:
                success = False
        except Exception:
            success = False
    return success


def export_sample(args, receipt, destination, transcript, audio, facts, include_audio):
    script = Path(__file__).resolve().parents[1] / 'training' / 'export.py'
    command = [sys.executable, str(script), '--base-url', args.origin,
               '--date', receipt['date'], '--sample-id', receipt['id'], '--output-dir', str(destination),
               '--token-file', str(args.token_file), '--no-proxy']
    process = subprocess.run(command, capture_output=True, timeout=180)
    if process.returncode != 0:
        raise RuntimeError('Owned sample export process failed')
    manifest = json.loads((destination / 'manifest.json').read_text())
    assert manifest['completed'] is True and manifest['sampleCount'] == 1
    assert manifest['sampleId'] == receipt['id'] and manifest['date'] == receipt['date']
    metadata = json.loads((destination / (receipt['id'] + '.json')).read_text())
    assert metadata['consentVersion'] == '1' and metadata['transcript'] == transcript
    assert metadata['correction'] == CORRECTION
    assert metadata['language'] is None
    persons = {person['name']: person for person in metadata['people']}
    assert len(metadata['people']) == 3 and set(persons) == set(connections.NAMES)
    for name, person in persons.items():
        assert person['facts'] == facts[name]
        assert person.get('company') == ('Google' if name == 'Paul Miller' else None)
    edges = metadata['connections']
    assert len(edges) == 2
    assert {(edge['type'], frozenset((edge['person1Name'], edge['person2Name']))) for edge in edges} == {
        ('sibling', frozenset(('James Smith', 'Paul Miller'))),
        ('colleague', frozenset(('Paul Miller', 'Dana Brown')))}
    wav = destination / (receipt['id'] + '.wav')
    if include_audio:
        assert metadata['audioSize'] == len(audio)
        assert metadata['audioSha256'] == hashlib.sha256(audio).hexdigest()
        assert wav.read_bytes() == audio
    else:
        assert metadata['audioSize'] == 0 and metadata['audioSha256'] is None and not wav.exists()
    assert {path.name for path in destination.iterdir()} == {
        'manifest.json', receipt['id'] + '.json', *([receipt['id'] + '.wav'] if include_audio else [])}


def open_report(page, facts):
    global PHASE
    PHASE = 'open report and verify consent controls'
    hosted.click(page, REPORT, force=True)
    submit = page.get_by_role('button', name='Beispiel senden', exact=True)
    expect(submit).to_be_visible()
    expect(submit).to_be_disabled()
    expect(page.get_by_role('checkbox', name=CONSENT, exact=True)).not_to_be_checked()
    expect(page.get_by_role('checkbox', name=AUDIO, exact=True)).to_be_checked()
    PHASE = 'verify report preview transcript and scoped extraction'
    preview = page.get_by_role('alertdialog').get_by_role('group')
    # Flutter's SelectableText has an empty disabled semantic textarea.
    # Screenshots show the preview; authenticated export verifies its exact text.
    expect(preview).to_contain_text('Vollständiger Geschichtentext (Notizen und alle Transkripte dieser Geschichte)')
    for name in connections.NAMES:
        PHASE = 'verify preview person: ' + name
        text = '\n'.join([name, *(['Google'] if name == 'Paul Miller' else []), *facts[name]])
        expect(preview).to_contain_text(text)
    PHASE = 'verify preview sibling connection'
    expect(preview).to_contain_text('James Smith und Paul Miller sind Geschwister.')
    PHASE = 'verify preview colleague connection'
    expect(preview).to_contain_text('Paul Miller ist Kollegin oder Kollege von Dana Brown.')
    return submit


def run(args):
    global PHASE
    args.output.mkdir(mode=0o700, parents=True)
    result = {'completed': False, 'uncaught_errors': 0, 'cleanup_verified': False,
              'upload_http_statuses': [], 'unauthorized_http_statuses': [],
              'delete_http_statuses': [], 'deleted_audio_http_statuses': []}
    result_path = args.output / 'result.json'
    training_export.atomic_json(result_path, result)
    owned = []
    errors = []
    client = None
    checks_passed = False
    try:
        PHASE = 'validate synthetic backup and protected review credential'
        transcript, audio, facts = fixture(args.backup)
        client = training_export.Client(args.origin, training_export.token_from_file(args.token_file), no_proxy=True)
        with hosted.chromium(args, args.output) as endpoint, sync_playwright() as playwright:
            browser = playwright.chromium.connect_over_cdp(endpoint)
            context = browser.new_context(viewport={'width': 1440, 'height': 900}, locale='de-DE', accept_downloads=True)
            page = context.new_page()
            page.set_default_timeout(45000)
            page.on('pageerror', lambda _: errors.append(True))
            posts = []
            receipt_errors = []

            def is_upload(request):
                return request.method == 'POST' and request.url == args.origin + '/api/training-samples'

            def capture(response):
                if not is_upload(response.request):
                    return
                result['upload_http_statuses'].append(response.status)
                if response.status != 201:
                    return
                try:
                    receipt = response.json()
                    identifier, day = receipt['id'], receipt['date']
                    if (not isinstance(identifier, str) or not training_export.ID.fullmatch(identifier)
                            or not isinstance(day, str) or datetime.date.fromisoformat(day).isoformat() != day):
                        raise ValueError()
                    if any(row['id'] == identifier for row in owned):
                        raise ValueError()
                    owned.append({'id': identifier, 'date': day})
                    training_export.atomic_json(args.output / 'owned-samples.json', owned)
                except Exception:
                    receipt_errors.append(True)

            page.on('request', lambda request: posts.append(True) if is_upload(request) else None)
            page.on('response', capture)
            try:
                PHASE = 'restore synthetic prior speech as isolated guest'
                people.guest(page, args.origin)
                hosted.settings(page)
                with page.expect_file_chooser() as chooser:
                    hosted.open_item(page, 'Aus Sicherung wiederherstellen')
                chooser.value.set_files(args.backup)
                hosted.click(page, 'Wiederherstellen')
                expect(page.get_by_text('Wiederherstellung abgeschlossen', exact=True)).to_be_visible()
                hosted.click(page, 'Fertig')
                hosted.click(page, 'Geschichten')
                hosted.open_item(page, connections.TITLE)
                PHASE = 'consent required and cancel sends no upload'
                open_report(page, facts)
                hosted.click(page, 'Abbrechen')
                expect(page.get_by_role('button', name='Beispiel senden', exact=True)).to_have_count(0)
                assert not posts
                result['consent_required_cancel_without_post'] = True
                for include_audio in (True, False):
                    PHASE = 'report synthetic recording' if include_audio else 'report synthetic transcript without audio'
                    submit = open_report(page, facts)
                    hosted.field(page, 'Korrektur oder Erklärung (optional)', CORRECTION)
                    if not include_audio:
                        page.get_by_role('checkbox', name=AUDIO, exact=True).click()
                        expect(page.get_by_role('checkbox', name=AUDIO, exact=True)).not_to_be_checked()
                    expect(submit).to_be_disabled()
                    hosted.screenshots(page, args.output, 'training-audio-form' if include_audio else 'training-metadata-form')
                    page.get_by_role('checkbox', name=CONSENT, exact=True).click()
                    expect(submit).to_be_enabled()
                    previous = len(owned)
                    with page.expect_response(lambda response: is_upload(response.request)) as upload:
                        submit.click()
                    response = upload.value
                    assert response.status == 201 and not receipt_errors and len(owned) == previous + 1
                    receipt = owned[-1]
                    expect(page.get_by_role('button', name='Schließen', exact=True)).to_be_visible()
                    hosted.screenshots(page, args.output, 'training-audio-success' if include_audio else 'training-metadata-success')
                    PHASE = 'export and verify owned submission'
                    export_sample(args, receipt, args.output / ('audio-export' if include_audio else 'metadata-export'),
                                  transcript, audio, facts, include_audio)
                    result['original_wav_exactly_preserved' if include_audio else 'metadata_only_without_wav'] = True
                    path = f"/api/training-samples/{receipt['date']}/{receipt['id']}/audio"
                    for denied in ('/api/training-samples?date=' + receipt['date'], path):
                        code = status(client, denied, reviewer=False)
                        result['unauthorized_http_statuses'].append(code)
                        assert code == 401
                    code = status(client, path, reviewer=False, extra_headers={'Authorization': 'Bearer synthetic.invalid.token'})
                    result['unauthorized_http_statuses'].append(code)
                    assert code == 401
                    hosted.click(page, 'Schließen')
                assert len(posts) == 2 and result['upload_http_statuses'] == [201, 201] and not errors
                result['exact_transcript_correction_scoped_people_connections'] = True
                result['guest_reviewer_access_denied'] = True
            except Exception:
                if page.url.startswith(args.origin):
                    try:
                        page.screenshot(path=str(args.output / 'failure.png'))
                        summary = page.locator('[role]').evaluate_all(r"""nodes => nodes.map(node => ({
                            role: node.getAttribute('role'),
                            label: node.getAttribute('aria-label') ||
                                (node.getAttribute('aria-labelledby') || '').split(/\s+/)
                                    .map(id => document.getElementById(id)?.textContent || '').join(' '),
                            text: (node.innerText || '').slice(0, 200)
                        }))""")
                        training_export.atomic_json(args.output / 'failure-ui.json', summary)
                    except Exception:
                        pass  # Keep the original failure if diagnostics cannot be saved.
                raise
            finally:
                context.close()
                browser.close()
        checks_passed = True
    finally:
        failed_phase = PHASE
        PHASE = 'delete and verify only owned submitted samples'
        result['cleanup_verified'] = cleanup(client, owned, result) if client is not None else not owned
        result['uncaught_errors'] = len(errors)
        result['completed'] = checks_passed and result['cleanup_verified'] and not errors
        training_export.atomic_json(result_path, result)
        if not checks_passed:
            PHASE = failed_phase
    if not result['completed']:
        raise RuntimeError('Training verification or owned sample cleanup failed')
    print(json.dumps(result), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='https://con.coflnet.com')
    parser.add_argument('--backup', type=Path, required=True, help='pinned synthetic prior real-ASR ZIP')
    parser.add_argument('--token-file', type=Path, required=True, help='owned mode-0600 reviewer credential')
    parser.add_argument('--output', type=Path, required=True, help='new private result directory')
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    args = parser.parse_args()
    args.origin = args.origin.rstrip('/')
    try:
        if training_export.origin(args.origin) != args.origin or (args.origin.startswith('https:') and args.origin != 'https://con.coflnet.com'):
            parser.error('Use hosted Con HTTPS or a loopback HTTP origin')
    except (ValueError, training_export.ExportError):
        parser.error('Use hosted Con HTTPS or a loopback HTTP origin')
    args.audio_fixture = None  # Existing Chromium lifecycle expects this; no capture is started.
    os.umask(0o077)
    try:
        run(args)
    except Exception as error:
        print('Con training E2E failed: ' + type(error).__name__ + '; phase=' + PHASE + '; control=' + hosted.PHASE, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
