#!/usr/bin/env python3
"""Export explicitly consented Con training samples through the reviewer API."""
import argparse
import datetime
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import wave

MAX_AUDIO = 10 * 1024 * 1024
MAX_METADATA = 4 * 1024 * 1024
MAX_PAGES = 10000
ID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z')
SHA256 = re.compile(r'[0-9a-f]{64}\Z')


class ExportError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def origin(value):
    parsed = urllib.parse.urlsplit(value)
    try:
        loopback = ipaddress.ip_address(parsed.hostname or '').is_loopback
    except ValueError:
        loopback = parsed.hostname == 'localhost'
    if (parsed.scheme not in ('https', 'http') or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or parsed.path not in ('', '/') or parsed.query or parsed.fragment
            or (parsed.scheme == 'http' and not loopback)):
        raise ExportError('base URL must be an HTTPS origin (HTTP only on loopback)')
    return value.rstrip('/')


def token_from_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'r', encoding='utf-8') as handle:
        info = os.fstat(handle.fileno())
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_uid != os.getuid()):
            raise ExportError('token file must be an owned regular mode-0600 file')
        return handle.read(514).strip()


def validate_token(token):
    if not token or not 32 <= len(token) <= 512 or any(ord(c) < 33 or ord(c) > 126 for c in token):
        raise ExportError('reviewer token must be 32–512 printable ASCII characters without whitespace')
    return token


def atomic_json(path, value):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix='.partial-', delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write('\n')
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


class Client:
    def __init__(self, base_url, token, no_proxy=False):
        self.base_url = origin(base_url)
        self.token = validate_token(token)
        handlers = [NoRedirect()]
        if no_proxy:
            handlers.append(urllib.request.ProxyHandler({}))
        self.opener = urllib.request.build_opener(*handlers)

    def get(self, path, query=None):
        url = self.base_url + path
        if query:
            url += '?' + urllib.parse.urlencode(query)
        request = urllib.request.Request(url, headers={'X-Training-Token': self.token,
                                                       'User-Agent': 'ConTrainingExport/1.0'})
        try:
            return self.opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            error.close()
            raise ExportError(f'GET /api/training-samples failed: HTTP {error.code}') from None
        except (urllib.error.URLError, ValueError):
            raise ExportError('GET /api/training-samples failed: connection error') from None

    def page(self, day, cursor):
        query = {'date': day, 'limit': 20}
        if cursor is not None:
            query['cursor'] = cursor
        with self.get('/api/training-samples', query) as response:
            raw = response.read(MAX_METADATA + 1)
        if len(raw) > MAX_METADATA:
            raise ExportError('sample metadata exceeds export limit')
        try:
            page = json.loads(raw)
        except (ValueError, UnicodeError):
            raise ExportError('invalid sample metadata JSON') from None
        if not isinstance(page, dict) or not isinstance(page.get('items'), list) or len(page['items']) > 20:
            raise ExportError('invalid sample page')
        cursor = page.get('nextCursor')
        if cursor is not None and (not isinstance(cursor, str) or not cursor or len(cursor) > 4096):
            raise ExportError('invalid sample cursor')
        return page['items'], cursor

    def audio(self, item, output):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=output, prefix='.partial-', delete=False) as handle:
                temporary = Path(handle.name)
                digest = hashlib.sha256()
                total = 0
                path = f"/api/training-samples/{item['date']}/{item['id']}/audio"
                with self.get(path) as response:
                    while chunk := response.read(65536):
                        total += len(chunk)
                        if total > item['audioSize'] or total > MAX_AUDIO:
                            raise ExportError('audio exceeds declared size or export limit')
                        digest.update(chunk)
                        handle.write(chunk)
            if total != item['audioSize'] or digest.hexdigest() != item['audioSha256']:
                raise ExportError('audio size or SHA-256 mismatch')
            try:
                with wave.open(str(temporary), 'rb') as audio:
                    if audio.getcomptype() != 'NONE':
                        raise ExportError('audio must be PCM WAV')
                    expected = audio.getnframes() * audio.getnchannels() * audio.getsampwidth()
                    if len(audio.readframes(audio.getnframes())) != expected:
                        raise ExportError('truncated PCM WAV')
            except (wave.Error, EOFError):
                raise ExportError('invalid PCM WAV') from None
            os.replace(temporary, output / (item['id'] + '.wav'))
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def validate_item(item, day):
    if (not isinstance(item, dict) or not isinstance(item.get('id'), str)
            or not ID.fullmatch(item['id']) or item.get('date') != day):
        raise ExportError('invalid sample ID or date')
    if item.get('consentVersion') != '1':
        raise ExportError('unsupported or missing explicit consent version')
    size = item.get('audioSize')
    digest = item.get('audioSha256')
    if (type(size) is not int or not 0 <= size <= MAX_AUDIO
            or (size == 0 and digest is not None)
            or (size > 0 and (not isinstance(digest, str) or not SHA256.fullmatch(digest)))):
        raise ExportError('invalid audio metadata')


def export(base_url, token, day, output, sample_id=None, no_proxy=False):
    try:
        if datetime.date.fromisoformat(day).isoformat() != day:
            raise ValueError()
    except ValueError:
        raise ExportError('date must be YYYY-MM-DD') from None
    if sample_id is not None and not ID.fullmatch(sample_id):
        raise ExportError('sample ID must be a lowercase canonical UUID')
    client = Client(base_url, token, no_proxy)
    output = Path(output)
    try:
        output.mkdir(mode=0o700)
    except FileExistsError:
        raise ExportError('output directory already exists; choose a fresh directory') from None
    manifest = {'date': day, 'completed': False, 'sampleCount': 0}
    if sample_id is not None:
        manifest['sampleId'] = sample_id
    atomic_json(output / 'manifest.json', manifest)
    cursor = None
    cursors = set()
    ids = set()
    for _ in range(MAX_PAGES):
        items, next_cursor = client.page(day, cursor)
        for item in items:
            validate_item(item, day)
            if sample_id is not None and item['id'] != sample_id:
                continue
            if item['id'] in ids:
                raise ExportError('duplicate sample ID')
            ids.add(item['id'])
            if item['audioSize']:
                client.audio(item, output)
            atomic_json(output / (item['id'] + '.json'), item)
        if next_cursor is None or (sample_id is not None and ids):
            if sample_id is not None and not ids:
                raise ExportError('selected sample was not found on this UTC day')
            manifest.update(completed=True, sampleCount=len(ids))
            atomic_json(output / 'manifest.json', manifest)
            return len(ids)
        if next_cursor in cursors:
            raise ExportError('repeated sample cursor')
        cursors.add(next_cursor)
        cursor = next_cursor
    raise ExportError('sample pagination exceeds export limit')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default='https://con.coflnet.com')
    parser.add_argument('--date', required=True, help='UTC day, YYYY-MM-DD')
    parser.add_argument('--output-dir', required=True, type=Path, help='new private export directory')
    parser.add_argument('--token-file', type=Path, help='owned mode-0600 reviewer token file')
    parser.add_argument('--sample-id', help='export only this lowercase canonical UUID')
    parser.add_argument('--no-proxy', action='store_true', help='ignore environment HTTP(S) proxies')
    args = parser.parse_args()
    try:
        token = token_from_file(args.token_file) if args.token_file else os.environ.get('CON_TRAINING_TOKEN')
        count = export(args.base_url, token, args.date, args.output_dir, args.sample_id, args.no_proxy)
    except ExportError as error:
        print(f'Export failed: {error}', file=sys.stderr)
        return 1
    except (OSError, ValueError, http.client.HTTPException):
        print('Export failed: local file or response error', file=sys.stderr)
        return 1
    print(f'Export complete: {count} samples')
    return 0


if __name__ == '__main__':
    sys.exit(main())
