"""Synthetic transcript relationships and person facts through the real Con UI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit
import wave
import zipfile

import hosted
import people
from playwright.sync_api import sync_playwright, expect

PHASE = 'startup'
SEED = 'My brother James Smith came.'
TEXT = ('James Smith got a new car. James Smith is the brother of Paul Miller, '
        'who works at Google and is a colleague of Dana Brown.')
SEED_TITLE = 'E2E Known James'
TITLE = 'Informationen über James Smith'
REPEAT_TITLE = 'E2E Repeated connections'
NAMES = ('James Smith', 'Paul Miller', 'Dana Brown')


def person(page, name):
    hosted.click(page, 'Personen')
    page.get_by_role('button', name=re.compile(re.escape(name))).first.click()
    expect(page.get_by_text(name, exact=True).first).to_be_visible()


def details(page, recorded):
    hosted.open_item(page, TITLE)
    for name in NAMES:
        expect(page.get_by_role('button', name=re.compile('^' + name[0] + r'\s+' + re.escape(name) + '$'))).to_be_visible()
    if recorded:
        hosted.playback(page)


def person_facts(page, output, screenshot):
    person(page, 'James Smith')
    expect(page.get_by_role('button', name=re.compile(r'James Smith got a new car', re.I)).first).to_be_visible()
    page.get_by_role('button', name=re.compile(re.escape(TITLE))).first.click()
    for name in NAMES:
        expect(page.get_by_role('button', name=re.compile('^' + name[0] + r'\s+' + re.escape(name) + '$'))).to_be_visible()
    hosted.back(page)
    hosted.screenshots(page, output, screenshot)
    hosted.back(page)


def archive_data(archive, recorded):
    with zipfile.ZipFile(archive) as bundle:
        data = json.loads(bundle.read('data.json'))
        persons = {row['data']['name']: row['data'] for row in data['persons']}
        assert set(persons) == set(NAMES)
        names = {name: row['id'] for name, row in persons.items()}
        stories = {row['data']['title']: row['data'] for row in data['events']}
        assert set(stories) == {SEED_TITLE, TITLE, REPEAT_TITLE}
        seed, info, repeated = (stories[t] for t in (SEED_TITLE, TITLE, REPEAT_TITLE))
        assert seed['participantIds'] == [names['James Smith']]
        assert seed['description'] == SEED and not seed['files']
        for story in (info, repeated):
            assert set(story['participantIds']) == set(names.values())
            assert story.get('placeId') is None
        assert repeated['description'] == TEXT and not repeated['files']
        for name, person_row in persons.items():
            assert person_row.get('notes') is None
            facts = person_row['storyFacts']
            if name == 'James Smith':
                assert set(facts) == {info['id'], repeated['id']}
                assert all(re.search(r'got a new car', value, re.I) for value in facts.values())
                assert person_row.get('company') is None
            elif name == 'Paul Miller':
                assert person_row['company'] == 'Google'
                assert set(facts) == {info['id'], repeated['id']}
                assert all(re.search(r'works at Google', value, re.I) for value in facts.values())
            else:
                assert not facts and person_row.get('company') is None
        connections = [row['data'] for row in data['connections']]
        assert len(connections) == 2
        expected = {('sibling', frozenset((names['James Smith'], names['Paul Miller']))),
                    ('colleague', frozenset((names['Paul Miller'], names['Dana Brown'])))}
        actual = {(row['relationshipType'], frozenset((row['person1Id'], row['person2Id'])))
                  for row in connections}
        assert actual == expected
        for connection in connections:
            assert connection['isInferred'] is True and connection['isDeleted'] is False
            assert connection['originEventId'] == info['id']
            assert set(connection['sourceEventIds']) == {info['id'], repeated['id']}
        if recorded:
            manifest = json.loads(bundle.read('manifest.json'))
            assert not manifest['missingAudio']
            recording, = manifest['recordings']
            attachment, = info['files']
            assert attachment['id'] == recording['id'] and attachment['kind'] == 'recording'
            wav = bundle.read('recordings/' + recording['id'] + '.wav')
            assert len(wav) == recording['size']
            assert hashlib.sha256(wav).hexdigest() == recording['sha256']
            assert re.search(r'James Smith got a new car', info['description'], re.I)
        else:
            assert info['description'] == TEXT and not info['files']
        # Compare complete serialized objects after reload/restore, including IDs.
        return {key: sorted((row['data'] for row in data[key]), key=lambda row: row['id'])
                for key in ('persons', 'events', 'connections')}


def scroll_proposals(page):
    page.mouse.move(page.viewport_size['width'] / 2, page.viewport_size['height'] / 2)
    page.mouse.wheel(0, 700)
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')


def run(args):
    global PHASE
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    recorded = args.audio_fixture is not None
    result = {'completed': False, 'recorded': recorded, 'origin': args.origin}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    errors = []
    with people.local_server(args, output), hosted.chromium(args, output) as endpoint, sync_playwright() as playwright:
        browser = playwright.chromium.connect_over_cdp(endpoint)
        contexts = [browser.new_context(viewport={'width': 1440, 'height': 900},
                    locale='de-DE', permissions=['microphone'], accept_downloads=True) for _ in range(2)]
        pages = []
        for context in contexts:
            if args.serve_directory:
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
            PHASE = 'isolated synthetic account or local guest'
            if args.fixture:
                hosted.login(page, args.origin, hosted.read_fixture(args.fixture)['users'][0])
            else:
                people.guest(page, args.origin)
            if recorded:
                hosted.settings(page)
                hosted.open_item(page, 'Sprache der Aufnahmen')
                page.get_by_role('radio', name='English', exact=True).click()
                expect(page.get_by_text('Einstellungen', exact=True)).to_be_visible()
                hosted.back(page)
            PHASE = 'seed known James through typed quick add'
            people.quick_add(page)
            hosted.field(page, 'Was ist hier passiert?', SEED)
            hosted.field(page, 'Titel (optional)', SEED_TITLE)
            expect(people.chip(page, 'James Smith')).to_be_visible()
            hosted.click(page, 'Geschichte speichern')
            PHASE = 'record information from known person detail'
            person(page, 'James Smith')
            hosted.click(page, 'Informationen aufnehmen')
            title = page.get_by_role('textbox', name=re.compile(r'Titel \*'))
            title.click()
            expect(title).to_have_value(TITLE)
            if recorded:
                statuses = []
                def capture(response):
                    if urlsplit(response.url).path == '/api/transcription/segment':
                        statuses.append(response.status)
                page.on('response', capture)
                hosted.click(page, 'Aufnahme starten')
                # Flutter's hovered tooltip can alter the computed accessible name.
                stop = page.locator('[role=button]').filter(has_text=re.compile(r'^Aufnahme beenden$'))
                expect(stop).to_have_count(1)
                expect(stop).to_be_enabled()
                PHASE = 'record synthetic information'
                with wave.open(str(args.audio_fixture)) as audio:
                    duration = audio.getnframes() / audio.getframerate()
                page.wait_for_timeout(int((duration + 1) * 1000))
                PHASE = 'finalize synthetic information recording'
                hosted.PHASE = 'UI control: Aufnahme beenden'
                stop.click(force=True)
                expect(page.get_by_role('button', name='Speichern', exact=True)).to_be_enabled(timeout=90000)
                transcript = page.get_by_role('textbox', name='Beschreibung', exact=True)
                transcript.click()
                expect(transcript).to_be_focused()
                expect(transcript).to_have_value(re.compile(r'Dana Brown', re.I), timeout=90000)
                page.remove_listener('response', capture)
                assert statuses and all(status == 200 for status in statuses)
                result['transcription_http_statuses'] = statuses
            else:
                hosted.field(page, 'Beschreibung', TEXT)
            for name in NAMES[1:]:
                expect(people.chip(page, name)).to_be_visible()
            expect(page.get_by_role('group', name=re.compile('Verbindungen und Informationen'))).to_be_visible()
            for label in ('James Smith · Schwester oder Bruder von Paul Miller',
                          'Paul Miller · Kollegin oder Kollege von Dana Brown'):
                expect(page.get_by_role('group', name=label, exact=True)).to_be_visible()
            expect(page.get_by_role('button', name='Vorschlag entfernen', exact=True)).to_have_count(4)
            hosted.screenshots(page, output, 'connections-draft')
            hosted.screenshots(page, output, 'connections-proposals', prepare=lambda: scroll_proposals(page))
            hosted.click(page, 'Speichern')
            expect(page.get_by_role('button', name='Speichern', exact=True)).to_have_count(0)
            expect(page.get_by_role('button', name='Informationen aufnehmen', exact=True)).to_be_visible()
            # The person entry returns to the original detail route.
            hosted.back(page)
            PHASE = 'repeat typed evidence without duplicate connections'
            person(page, 'James Smith')
            hosted.click(page, 'Informationen aufnehmen')
            hosted.field(page, 'Titel *', REPEAT_TITLE)
            hosted.field(page, 'Beschreibung', TEXT)
            hosted.click(page, 'Speichern')
            expect(page.get_by_role('button', name='Speichern', exact=True)).to_have_count(0)
            expect(page.get_by_role('button', name='Informationen aufnehmen', exact=True)).to_be_visible()
            hosted.back(page)
            hosted.click(page, 'Geschichten')
            details(page, recorded)
            hosted.screenshots(page, output, 'connections-story')
            hosted.back(page)
            person_facts(page, output, 'connections-person-facts')
            PHASE = 'export verifies subject attribution and deduplication'
            expected_data = archive_data(people.export(page, output, 'connections-backup.zip'), recorded)
            result['exact_subjects_facts_connections_sources'] = True
            PHASE = 'reload preserves every serialized ID and fact'
            page.reload()
            hosted.semantics(page)
            hosted.click(page, 'Geschichten')
            details(page, recorded)
            hosted.back(page)
            person_facts(page, output, 'connections-reloaded')
            assert archive_data(people.export(page, output, 'connections-reloaded.zip'), recorded) == expected_data
            result['reload_preserved_exact_data'] = True
            PHASE = 'fresh browser context restores every serialized ID and fact'
            people.guest(restore, args.origin)
            hosted.settings(restore)
            with restore.expect_file_chooser() as chooser:
                hosted.open_item(restore, 'Aus Sicherung wiederherstellen')
            chooser.value.set_files(output / 'connections-backup.zip')
            hosted.click(restore, 'Wiederherstellen')
            expect(restore.get_by_text('Wiederherstellung abgeschlossen', exact=True)).to_be_visible()
            hosted.click(restore, 'Fertig')
            hosted.click(restore, 'Geschichten')
            details(restore, recorded)
            hosted.back(restore)
            person_facts(restore, output, 'connections-restored')
            assert archive_data(people.export(restore, output, 'connections-restored.zip'), recorded) == expected_data
            result['fresh_restore_preserved_exact_data'] = True
            result['recording_playback_reload_restore'] = recorded
            assert not errors
            result['completed'] = True
            print(json.dumps(result), flush=True)
        except Exception:
            for index, failed in enumerate(pages):
                if failed.url.startswith(args.origin):
                    failed.screenshot(path=str(output / f'failure-{index}.png'))
                    summary = failed.locator('[role]').evaluate_all("nodes => nodes.map(e => { const r=e.getBoundingClientRect(); return {role:e.getAttribute('role'),label:e.getAttribute('aria-label'),labelledBy:(e.getAttribute('aria-labelledby')||'').split(/\\s+/).map(id=>document.getElementById(id)?.textContent||'').join(' '),text:(e.innerText||'').slice(0,200),box:{x:r.x,y:r.y,width:r.width,height:r.height},display:getComputedStyle(e).display,visibility:getComputedStyle(e).visibility}; })")
                    (output / f'failure-ui-{index}.json').write_text(json.dumps(summary, ensure_ascii=False))
                    title_field = failed.get_by_role('textbox', name=re.compile(r'Titel \*'))
                    description = failed.get_by_role('textbox', name='Beschreibung', exact=True)
                    if title_field.count() == 1 and description.count() == 1 and title_field.input_value() in (TITLE, REPEAT_TITLE):
                        (output / f'failure-synthetic-form-{index}.json').write_text(json.dumps({'title': title_field.input_value(), 'description': description.input_value()}, ensure_ascii=False))
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
    parser.add_argument('--serve-directory', type=Path)
    parser.add_argument('--fixture', help='Protected disposable hosted identity fixture')
    parser.add_argument('--audio-fixture', type=Path, help='Fictional 16-kHz mono PCM WAV; hosted fixture required')
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    args = parser.parse_args()
    args.origin = args.origin.rstrip('/')
    if args.origin not in ('http://127.0.0.1:18085', 'http://localhost:18085', 'https://con.coflnet.com'):
        parser.error('Use localhost port 18085 or hosted Con HTTPS origin')
    if args.serve_directory and (args.origin.startswith('https:') or not (args.serve_directory / 'index.html').is_file()):
        parser.error('Local serving requires an existing web build and localhost origin')
    if args.fixture and args.origin != 'https://con.coflnet.com':
        parser.error('Identity fixtures are accepted only for hosted Con')
    if args.origin == 'https://con.coflnet.com' and (not args.fixture or not args.audio_fixture):
        parser.error('Hosted verification requires a synthetic identity and fictional speech WAV')
    if args.audio_fixture:
        if not args.fixture or not args.audio_fixture.is_file():
            parser.error('Real speech requires a hosted fixture and existing fictional WAV')
        with wave.open(str(args.audio_fixture)) as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000) or not 11 <= audio.getnframes() / 16000 <= 20:
                parser.error('Fictional WAV must be 11–20 seconds, 16-kHz mono PCM')
    os.umask(0o077)
    try:
        run(args)
    except Exception as error:
        print('Con connections E2E failed: ' + type(error).__name__ + '; phase=' + PHASE + '; control=' + hosted.PHASE, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
