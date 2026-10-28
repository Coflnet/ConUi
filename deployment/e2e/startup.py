"""Verify Con's static startup shell and guest-first UI without signing in.

Use --serve-directory flutter_app/build/web --origin http://127.0.0.1:18085
for a local release build, or --origin https://con.coflnet.com for public guest
checks. All stories and drafts use an isolated browser profile and stay local.
"""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

import hosted
import people
from playwright.sync_api import sync_playwright, expect

PHASE = 'startup'


def capture(page, output, name):
    page.screenshot(path=str(output / (name + '.png')))
    (output / (name + '.txt')).write_text(page.locator('body').aria_snapshot())


def ready(page, words):
    hosted.semantics(page)
    expect(page.get_by_role('button', name=words['settingsTitle'], exact=True)).to_be_visible()
    expect(page.locator('#startup')).to_have_count(0)


def reveal(page, target):
    # Flutter's virtual list scrolls on canvas, not via DOM scrollIntoView.
    for _ in range(8):
        box = target.bounding_box() if target.count() else None
        if box and box['y'] >= 64 and box['y'] + box['height'] <= page.viewport_size['height']:
            return
        delta = max(-600, min(600, box['y'] - 80)) if box else 600
        page.mouse.move(page.viewport_size['width'] // 2, page.viewport_size['height'] // 2)
        page.mouse.wheel(0, delta)
        page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    raise AssertionError('Requested control was not reachable by scrolling')


def run(args):
    global PHASE
    args.output.mkdir(parents=True, exist_ok=True)
    result = {'completed': False, 'origin': args.origin, 'layouts': []}
    receipt = args.output / 'result.json'
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    with people.local_server(args, args.output), hosted.chromium(args, args.output) as endpoint, sync_playwright() as p:
        browser = p.chromium.connect_over_cdp(endpoint)
        def context(locale='de-DE', width=390, javascript=True, scale=1, hold=False, failure=None):
            ctx = browser.new_context(locale=locale, viewport={'width': width, 'height': 844 if width == 390 else 900},
                                      java_script_enabled=javascript, service_workers='block')
            def route(request):
                url = urlsplit(request.request.url)
                if request.request.method != 'GET':
                    raise RuntimeError('Startup review attempted a non-GET network request')
                if hold and url.path.endswith('/flutter_bootstrap.js'):
                    return request.fulfill(content_type='application/javascript', body='/* bootstrap deliberately held for static-shell review */')
                if failure is not None and failure['active'] and url.path.endswith('/main.dart.js'):
                    failure['requests'] += 1
                    return request.abort()
                if args.serve_directory and url.hostname == 'www.gstatic.com' and '/flutter-canvaskit/' in url.path:
                    asset = args.serve_directory / 'canvaskit' / Path(*url.path.split('/')[3:])
                    return request.fulfill(path=asset, headers={'Access-Control-Allow-Origin': '*'})
                if scale != 1 and request.request.resource_type == 'document' and request.request.url.rstrip('/') == args.origin:
                    response = request.fetch()
                    body = response.text().replace('</head>', f'<style>html {{font-size: {16 * scale}px;}}</style></head>')
                    return request.fulfill(response=response, body=body)
                request.continue_()
            ctx.route('**/*', route)
            return ctx
        page = None
        try:
            for locale in ('de-DE', 'en-GB'):
                words = json.loads((Path(__file__).resolve().parents[2] / 'flutter_app/lib/l10n' /
                                    ('app_de.arb' if locale.startswith('de') else 'app_en.arb')).read_text())
                PHASE = locale + ': static shell before Flutter'
                ctx = context(locale, hold=True)
                page = ctx.new_page()
                page.goto(args.origin, wait_until='domcontentloaded')
                expect(page.locator('#startup h1')).to_be_visible()
                expect(page.locator('#loading')).to_be_visible()
                expect(page.locator('#retry')).to_be_hidden()
                assert page.title().startswith('Con')
                assert len(page.locator('meta[name="description"]').get_attribute('content')) > 50
                assert page.locator('link[rel="canonical"]').get_attribute('href') == 'https://con.coflnet.com/'
                for key in ('title', 'description', 'image', 'url', 'type'):
                    assert page.locator(f'meta[property="og:{key}"]').get_attribute('content')
                assert page.locator('html').get_attribute('lang') == locale[:2]
                capture(page, args.output, locale + '-static')
                ctx.close()

                PHASE = locale + ': actual main script failure and reload recovery'
                failure = {'active': True, 'requests': 0}
                ctx = context(locale, failure=failure)
                page = ctx.new_page()
                page.goto(args.origin, wait_until='domcontentloaded')
                expect(page.locator('#retry')).to_be_visible(timeout=90000)
                assert failure['requests'] > 0
                expect(page.locator('#startup h1')).to_be_visible()
                capture(page, args.output, locale + '-load-failed')
                failure['active'] = False
                page.locator('#retry').click()
                ready(page, words)
                ctx.close()

                for width, scale in ((390, 1), (1440, 1), (390, 2)):
                    layout = f'{locale}: guest {width}px text {scale}x'
                    PHASE = layout + ': home readiness'
                    ctx = context(locale, width, scale=scale)
                    page = ctx.new_page()
                    errors = []
                    page.on('pageerror', lambda _: errors.append(True))
                    navigations = []
                    page.on('framenavigated', lambda frame: navigations.append(urlsplit(frame.url).netloc) if frame == page.main_frame else None)
                    page.goto(args.origin, wait_until='domcontentloaded')
                    ready(page, words)
                    PHASE = layout + ': four primary navigation destinations'
                    navigation = page.get_by_role('tab').or_(page.get_by_role(
                        'button', name=re.compile(r' Tab [1-4] (?:von|of) 4$')))
                    expect(navigation).to_have_count(4)
                    title = 'Deine Geschichten. Ohne Konto.' if locale.startswith('de') else 'Your stories. No account needed.'
                    cta = 'Erste Geschichte festhalten' if locale.startswith('de') else 'Create your first story'
                    PHASE = layout + ': welcome title'
                    expect(page.get_by_role('group', name=re.compile('^' + re.escape(title)))).to_be_visible()
                    first = page.get_by_role('button', name=cta, exact=True)
                    PHASE = layout + ': first story action'
                    expect(first).to_be_visible()
                    PHASE = layout + ': no default login'
                    expect(page.get_by_role('button', name=words['loginGoogleButton'], exact=True)).to_have_count(0)
                    name = f'{locale}-{width}-text{scale}'
                    capture(page, args.output, name + '-home')
                    PHASE = layout + ': first story action fits viewport'
                    box = first.bounding_box()
                    result['last_geometry'] = {'action': box, 'viewport': page.viewport_size}
                    assert box and box['x'] >= 0 and box['x'] + box['width'] <= width + 1, 'First-story action extends outside viewport'
                    PHASE = layout + ': document fits viewport'
                    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Document overflows horizontally'
                    if scale == 2:
                        PHASE = layout + ': text scaling applied'
                        assert page.locator('html').evaluate('el => getComputedStyle(el).fontSize') == '32px'
                    PHASE = layout + ': create and save draft'
                    first.click()
                    story = 'Synthetic startup story ' + name
                    hosted.field(page, words['addEventTitleFieldLabel'], story)
                    # A saved draft survives an optional account screen visit.
                    hosted.back(page)
                    hosted.click(page, words['storyDraftSave'])
                    PHASE = layout + ': optional account visit returns to Settings'
                    hosted.click(page, words['settingsTitle'])
                    reveal(page, page.get_by_role('button', name=re.compile('^' + re.escape(words['loginAccountButton']))))
                    hosted.open_item(page, words['loginAccountButton'])
                    expect(page.get_by_role('button', name=words['loginGoogleButton'], exact=True)).to_be_visible()
                    hosted.click(page, words['loginContinueWithoutAccount'])
                    expect(page.get_by_text(words['settingsTitle'], exact=True)).to_be_visible()
                    PHASE = layout + ': saved draft preserved'
                    hosted.back(page)
                    hosted.click(page, cta)
                    expect(page.get_by_text(words['storyDraftRestored'], exact=True)).to_be_visible()
                    field = page.get_by_role('textbox', name=re.compile(re.escape(words['addEventTitleFieldLabel'])))
                    field.click()
                    expect(field).to_have_value(story)
                    PHASE = layout + ': enter story description'
                    reveal(page, page.get_by_role('textbox', name=re.compile(re.escape(words['addEventDescriptionLabel']))))
                    hosted.field(page, words['addEventDescriptionLabel'], 'Synthetic account-free story retained on this device.')
                    PHASE = layout + ': save local story'
                    hosted.click(page, words['commonSave'])
                    hosted.click(page, words['homeNavStories'])
                    expect(page.get_by_role('button', name=re.compile('^' + re.escape(story)))).to_be_visible()
                    PHASE = layout + ': saved story survives reload'
                    page.reload(wait_until='domcontentloaded')
                    ready(page, words)
                    hosted.click(page, words['homeNavStories'])
                    expect(page.get_by_role('button', name=re.compile('^' + re.escape(story)))).to_be_visible()
                    capture(page, args.output, name + '-saved')
                    PHASE = layout + ': no script errors or identity redirects'
                    assert not errors
                    assert all(host == urlsplit(args.origin).netloc for host in navigations)
                    result['layouts'].append({'locale': locale, 'width': width, 'text_scale': scale,
                                              'guest_home': True, 'optional_account_returns': True,
                                              'draft_preserved': True, 'story_survives_reload': True})
                    ctx.close()
            PHASE = 'JavaScript disabled'
            ctx = context(javascript=False)
            page = ctx.new_page()
            page.goto(args.origin, wait_until='domcontentloaded')
            expect(page.locator('#startup h1')).to_be_visible()
            expect(page.locator('#javascript-guidance')).to_be_visible()
            expect(page.locator('#javascript-guidance')).to_contain_text('JavaScript')
            expect(page.locator('#loading')).to_be_hidden()
            capture(page, args.output, 'javascript-disabled')
            ctx.close()
            result.update(completed=True, static_seo=True, real_script_failure_retry=True, javascript_disabled_copy=True)
        finally:
            result['last_phase'] = PHASE
            if not result['completed'] and page is not None and not page.is_closed():
                capture(page, args.output, 'failure')
            receipt.write_text(json.dumps(result, indent=2) + '\n')
            browser.close()
    print(json.dumps({'completed': True, 'layouts': len(result['layouts'])}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='https://con.coflnet.com')
    parser.add_argument('--serve-directory', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    args = parser.parse_args()
    args.origin = args.origin.rstrip('/')
    if args.origin not in ('http://127.0.0.1:18085', 'https://con.coflnet.com'):
        parser.error('Use the exact public Con origin or owned localhost port 18085')
    if args.serve_directory and (args.origin.startswith('https:') or not (args.serve_directory / 'index.html').is_file()):
        parser.error('Local serving requires an existing build and localhost origin')
    args.audio_fixture = None
    run(args)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Startup review failed: ' + type(error).__name__ + '; phase=' + PHASE)
        raise SystemExit(1) from None
