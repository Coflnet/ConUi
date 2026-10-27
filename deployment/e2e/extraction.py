"""Synthetic guest-only transcript extraction, source navigation and ZIP checks."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit
import zipfile

import connections
import hosted
import people
from playwright.sync_api import expect, sync_playwright

PHASE = 'startup'
TITLE = 'E2E Personal fact extraction'
TEXT = ('Clara wohnt in Dr.-Müller-Straße 7, Wohnung 4B. '
        'Nora wohnt in Bonn, nein, in Köln. Jana hat einen Hund namens Milo. '
        'Jana zieht nächsten Monat nach Bremen. Mara hat am 12. März 1992 Geburtstag. '
        'Greta spielt jeden Donnerstag Volleyball. Eva ist Zahnärztin. '
        'Noah hat die Telefonnummer 030 123456. Hugo wohnte früher in Bonn. '
        'Iris ist nach Hamburg gezogen. Karl und Lena wohnen zusammen in Berlin '
        'und Paul arbeitet bei Bosch. Sara wohnt nicht in Bonn, aber Tim wohnt in Ulm. '
        'Quinn lives in Berlin or Hamburg.')
FACTS = {
    'Clara': 'Clara wohnt in Dr.-Müller-Straße 7, Wohnung 4B',
    'Nora': 'Nora wohnt in Bonn, nein, in Köln',
    'Jana': 'Jana hat einen Hund namens Milo\nJana zieht nächsten Monat nach Bremen',
    'Mara': 'Mara hat am 12. März 1992 Geburtstag',
    'Greta': 'Greta spielt jeden Donnerstag Volleyball',
    'Eva': 'Eva ist Zahnärztin',
    'Noah': 'Noah hat die Telefonnummer 030 123456',
    'Hugo': 'Hugo wohnte früher in Bonn',
    'Iris': 'Iris ist nach Hamburg gezogen',
    'Karl': 'Karl und Lena wohnen zusammen in Berlin',
    'Lena': 'Karl und Lena wohnen zusammen in Berlin',
    'Paul': 'Paul arbeitet bei Bosch',
    'Tim': 'aber Tim wohnt in Ulm',
}


def archive_data(archive):
    with zipfile.ZipFile(archive) as bundle:
        data = json.loads(bundle.read('data.json'))
    persons = [row['data'] for row in data['persons']]
    assert len(persons) == 13 and {row['name'] for row in persons} == set(FACTS)
    story, = [row['data'] for row in data['events']]
    assert story['title'] == TITLE and story['description'] == TEXT
    ids = [row['id'] for row in persons]
    assert len(story['participantIds']) == 13 and set(story['participantIds']) == set(ids)
    assert not story['files'] and not data['connections']
    for row in persons:
        assert row['storyFacts'] == {story['id']: FACTS[row['name']]}
        assert row.get('address') is None
        assert row.get('company') == ('Bosch' if row['name'] == 'Paul' else None)
    return {key: sorted((row['data'] for row in data[key]), key=lambda row: row['id'])
            for key in ('persons', 'events', 'connections')}


def source_navigation(page, output, screenshot=False):
    connections.person(page, 'Clara')
    fact = page.get_by_role('button', name=re.compile('^' + re.escape(FACTS['Clara'])))
    expect(fact).to_be_visible()
    if screenshot:
        hosted.screenshots(page, output, 'extraction-clara-source')
    fact.click(force=True)
    expect(page.get_by_text(TITLE, exact=True)).to_be_visible()
    hosted.back(page)
    hosted.back(page)


def run(args):
    global PHASE
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    result = {'completed': False, 'origin': args.origin, 'synthetic_guest_only': True,
              'recorded': False}
    receipt = output / 'result.json'
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    errors = []
    with people.local_server(args, output), hosted.chromium(args, output) as endpoint, sync_playwright() as playwright:
        browser = playwright.chromium.connect_over_cdp(endpoint)
        context = browser.new_context(locale='de-DE', viewport={'width': 1440, 'height': 900},
                                      accept_downloads=True)
        if args.serve_directory:
            def renderer(route):
                parts = urlsplit(route.request.url).path.split('/')[3:]
                asset = args.serve_directory / 'canvaskit' / Path(*parts)
                route.fulfill(path=asset, headers={'Access-Control-Allow-Origin': '*'})
            context.route(re.compile(r'^https://www\.gstatic\.com/flutter-canvaskit/[a-f0-9]+/(?:chromium/)?canvaskit\.(?:js|wasm)(?:\?.*)?$'), renderer)
        page = context.new_page()
        page.set_default_timeout(45000)
        page.on('pageerror', lambda _: errors.append(True))
        try:
            PHASE = 'guest typed story proposals'
            people.guest(page, args.origin)
            people.quick_add(page)
            hosted.field(page, 'Was ist hier passiert?', TEXT)
            hosted.field(page, 'Titel (optional)', TITLE)
            for name in FACTS:
                expect(people.chip(page, name)).to_have_count(1)
            for name in ('Milo', 'Sara', 'Quinn'):
                expect(people.chip(page, name)).to_have_count(0)
            expect(page.get_by_role('button', name='Vorschlag entfernen', exact=True)).to_have_count(14)
            hosted.screenshots(page, output, 'extraction-draft')
            hosted.click(page, 'Geschichte speichern')
            expect(page.get_by_text('Neue Geschichte', exact=True)).to_have_count(0)
            PHASE = 'person source story navigation'
            source_navigation(page, output, screenshot=True)
            result['person_fact_source_link'] = True
            PHASE = 'ZIP exact subjects sources and preserved contact fields'
            expected = archive_data(people.export(page, output, 'extraction-backup.zip'))
            result['exact_13_people_participants_and_source_facts'] = True
            result['no_invented_relationship_or_address'] = True
            result['employer_attributed_to_paul'] = True
            PHASE = 'reload exact persistence'
            page.reload(wait_until='domcontentloaded')
            hosted.semantics(page)
            source_navigation(page, output)
            assert archive_data(people.export(page, output, 'extraction-reloaded.zip')) == expected
            result['reload_preserved_exact_data'] = True
            assert not errors
            result['completed'] = True
            print(json.dumps(result), flush=True)
        except Exception as error:
            result.update(phase=PHASE, error=type(error).__name__)
            page.screenshot(path=str(output / 'failure.png'))
            raise
        finally:
            result['uncaught_errors'] = len(errors)
            receipt.write_text(json.dumps(result, indent=2) + '\n')
            context.close()
            browser.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='http://127.0.0.1:18085')
    parser.add_argument('--serve-directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    args = parser.parse_args()
    args.origin = args.origin.rstrip('/')
    if args.origin not in ('http://127.0.0.1:18085', 'http://localhost:18085', 'https://con.coflnet.com'):
        parser.error('Use localhost port 18085 or hosted Con HTTPS origin')
    if args.serve_directory and (args.origin.startswith('https:') or not (args.serve_directory / 'index.html').is_file()):
        parser.error('Local serving requires an existing web build and localhost origin')
    args.audio_fixture = None
    os.umask(0o077)
    try:
        run(args)
    except Exception as error:
        print('Con extraction E2E failed: ' + type(error).__name__ + '; phase=' + PHASE
              + '; control=' + hosted.PHASE, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
