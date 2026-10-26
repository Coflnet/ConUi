"""Read-only fresh-profile Con page-load measurements; no accounts or recordings."""
import argparse
import json
from pathlib import Path
import statistics
import time
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

from hosted import chromium, semantics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='https://con.coflnet.com')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--trials', type=int, default=3, choices=range(1, 11))
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--browser-arg', action='append', default=[])
    args = parser.parse_args()
    origin = urlsplit(args.origin)
    if origin.scheme not in ('http', 'https') or not origin.netloc or origin.query or origin.fragment or origin.username or origin.password:
        parser.error('--origin must be a public HTTP(S) origin without credentials, query or fragment')
    args.audio_fixture = None
    args.output.mkdir(parents=True, exist_ok=True)
    result = {'completed': False, 'trials': []}
    receipt = args.output / 'result.json'
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    with chromium(args, args.output) as endpoint, sync_playwright() as playwright:
        browser = playwright.chromium.connect_over_cdp(endpoint)
        for trial in range(args.trials):
            context = browser.new_context(locale='en-US')
            try:
                page = context.new_page()
                errors = []
                page.on('pageerror', lambda _: errors.append('pageerror'))
                for cache in ('cold', 'warm'):
                    start = time.monotonic()
                    page.goto(args.origin, wait_until='domcontentloaded', timeout=90000)
                    semantics(page)
                    page.get_by_role('button', name='Continue without account', exact=True).wait_for(timeout=90000)
                    ready_ms = round((time.monotonic() - start) * 1000)
                    resources = page.evaluate("""performance.getEntriesByType('resource').map(x => ({
                        path: new URL(x.name).pathname, start_ms: Math.round(x.startTime),
                        end_ms: Math.round(x.responseEnd), transfer_bytes: x.transferSize,
                        encoded_bytes: x.encodedBodySize, decoded_bytes: x.decodedBodySize
                    }))""")
                    result['trials'].append({'trial': trial, 'cache': cache, 'ready_ms': ready_ms,
                        'uncaught_errors': len(errors), 'resources': resources})
                    receipt.write_text(json.dumps(result, indent=2) + '\n')
                    if errors:
                        raise RuntimeError('Uncaught browser error')
            finally:
                context.close()
        browser.close()
    result['completed'] = True
    result['median_ready_ms'] = {cache: statistics.median(
        trial['ready_ms'] for trial in result['trials'] if trial['cache'] == cache)
        for cache in ('cold', 'warm')}
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'completed': True, 'median_ready_ms': result['median_ready_ms']}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Load measurement failed: ' + type(error).__name__)
        raise SystemExit(1)
