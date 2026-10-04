import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import stat
import tempfile
import threading
import unittest
import urllib.parse
import wave

import export

DAY = '2026-10-04'
TOKEN = 'synthetic-reviewer-token-for-local-tests-only'
FIRST = '11111111-1111-4111-8111-111111111111'
SECOND = '22222222-2222-4222-8222-222222222222'


def pcm_wav():
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b'\x00\x00' * 160)
    return buffer.getvalue()


WAV = pcm_wav()


def item(identifier=FIRST, audio=True):
    return {'id': identifier, 'date': DAY, 'createdAt': DAY + 'T12:00:00Z',
            'consentVersion': '1', 'transcript': 'Fictional example',
            'correction': None, 'language': 'en', 'people': [], 'connections': [],
            'audioSize': len(WAV) if audio else 0,
            'audioSha256': hashlib.sha256(WAV).hexdigest() if audio else None,
            'dataSha256': '0' * 64}


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.output = Path(self.temporary.name) / 'export'
        self.requests = []
        self.user_agents = []
        self.respond = lambda path: (200, {'items': [item()], 'nextCursor': None})
        self.audio = WAV
        test = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                test.requests.append((self.path, self.headers.get('X-Training-Token')))
                test.user_agents.append(self.headers.get('User-Agent'))
                if self.headers.get('X-Training-Token') != TOKEN:
                    self.send_response(403)
                    self.end_headers()
                    return
                if self.path.endswith('/audio'):
                    status, body = 200, test.audio
                else:
                    status, body = test.respond(self.path)
                self.send_response(status)
                if status == 302:
                    self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/steal')
                self.end_headers()
                self.wfile.write(body if isinstance(body, bytes) else json.dumps(body).encode())

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def run_export(self, token=TOKEN, **options):
        return export.export(self.base_url, token, DAY, self.output, **options)

    def manifest(self):
        return json.loads((self.output / 'manifest.json').read_text())

    def assert_incomplete(self):
        self.assertFalse(self.manifest()['completed'])
        self.assertEqual([], list(self.output.glob('.partial-*')))

    def test_authenticated_paginated_audio_and_metadata_only_export(self):
        def page(path):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
            self.assertEqual([DAY], query['date'])
            self.assertEqual(['20'], query['limit'])
            if 'cursor' not in query:
                return 200, {'items': [item()], 'nextCursor': 'opaque+/= cursor'}
            self.assertEqual(['opaque+/= cursor'], query['cursor'])
            return 200, {'items': [item(SECOND, audio=False)], 'nextCursor': None}
        self.respond = page
        self.assertEqual(2, self.run_export())
        self.assertEqual(WAV, (self.output / (FIRST + '.wav')).read_bytes())
        self.assertEqual(item(), json.loads((self.output / (FIRST + '.json')).read_text()))
        self.assertFalse((self.output / (SECOND + '.wav')).exists())
        self.assertEqual({'date': DAY, 'completed': True, 'sampleCount': 2}, self.manifest())
        self.assertEqual(3, len(self.requests))
        self.assertEqual(['ConTrainingExport/1.0'] * 3, self.user_agents)
        self.assertTrue(all(token == TOKEN for _, token in self.requests))
        self.assertTrue(all(TOKEN not in path for path, _ in self.requests))
        self.assertEqual(0o700, stat.S_IMODE(self.output.stat().st_mode))
        self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in self.output.iterdir()))

    def test_selected_sample_saves_only_matching_record_and_stops_paging(self):
        def page(path):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
            if 'cursor' not in query:
                return 200, {'items': [item(FIRST, audio=False)], 'nextCursor': 'second'}
            return 200, {'items': [item(SECOND)], 'nextCursor': 'unused'}
        self.respond = page
        self.assertEqual(1, self.run_export(sample_id=SECOND, no_proxy=True))
        self.assertEqual(3, len(self.requests))
        self.assertEqual({'manifest.json', SECOND + '.json', SECOND + '.wav'},
                         {path.name for path in self.output.iterdir()})
        self.assertEqual(SECOND, self.manifest()['sampleId'])
        self.assertTrue(self.manifest()['completed'])

    def test_missing_selected_sample_fails_without_persisting_other_samples(self):
        with self.assertRaisesRegex(export.ExportError, 'selected sample was not found'):
            self.run_export(sample_id=SECOND)
        self.assertEqual(['manifest.json'], [path.name for path in self.output.iterdir()])
        self.assertEqual(1, len(self.requests))
        self.assert_incomplete()

    def test_unauthorized_response_is_sanitized(self):
        with self.assertRaisesRegex(export.ExportError, r'^GET /api/training-samples failed: HTTP 403$'):
            self.run_export(token='another-invalid-reviewer-token-for-testing')
        self.assert_incomplete()

    def test_redirect_is_denied_without_forwarding_credentials(self):
        self.respond = lambda path: (302, b'private response must not be logged')
        with self.assertRaisesRegex(export.ExportError, 'HTTP 302'):
            self.run_export()
        self.assertEqual(1, len(self.requests))
        self.assert_incomplete()

    def test_wrong_checksum_never_commits_audio(self):
        wrong = item()
        wrong['audioSha256'] = '0' * 64
        self.respond = lambda path: (200, {'items': [wrong]})
        with self.assertRaisesRegex(export.ExportError, 'SHA-256 mismatch'):
            self.run_export()
        self.assertFalse((self.output / (FIRST + '.wav')).exists())
        self.assert_incomplete()

    def test_oversized_audio_stops_without_committing_file(self):
        wrong = item()
        wrong['audioSize'] = len(WAV) - 1
        self.respond = lambda path: (200, {'items': [wrong]})
        with self.assertRaisesRegex(export.ExportError, 'exceeds declared size'):
            self.run_export()
        self.assert_incomplete()

    def test_path_traversal_and_wrong_day_are_rejected_before_audio_request(self):
        for changes in ({'id': '../escape'}, {'date': '../escape'}, {'date': '2026-10-03'}):
            with self.subTest(changes=changes):
                unsafe = item()
                unsafe.update(changes)
                self.respond = lambda path: (200, {'items': [unsafe]})
                self.output = Path(self.temporary.name) / ('export-' + str(len(self.requests)))
                count = len(self.requests)
                with self.assertRaisesRegex(export.ExportError, 'invalid sample ID or date'):
                    self.run_export()
                self.assertEqual(count + 1, len(self.requests))
                self.assert_incomplete()

    def test_missing_consent_is_rejected(self):
        unsafe = item(audio=False)
        del unsafe['consentVersion']
        self.respond = lambda path: (200, {'items': [unsafe]})
        with self.assertRaisesRegex(export.ExportError, 'consent version'):
            self.run_export()
        self.assert_incomplete()

    def test_repeated_cursor_stops(self):
        self.respond = lambda path: (200, {'items': [], 'nextCursor': 'same'})
        with self.assertRaisesRegex(export.ExportError, 'repeated sample cursor'):
            self.run_export()
        self.assertEqual(2, len(self.requests))
        self.assert_incomplete()

    def test_existing_directory_is_never_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / 'owner-data'
        sentinel.write_text('preserve')
        with self.assertRaisesRegex(export.ExportError, 'already exists'):
            self.run_export()
        self.assertEqual('preserve', sentinel.read_text())
        self.assertEqual([], self.requests)

    def test_hash_matched_non_wav_is_rejected(self):
        self.audio = b'not a PCM WAV'
        wrong = item()
        wrong.update(audioSize=len(self.audio), audioSha256=hashlib.sha256(self.audio).hexdigest())
        self.respond = lambda path: (200, {'items': [wrong]})
        with self.assertRaisesRegex(export.ExportError, 'invalid PCM WAV'):
            self.run_export()
        self.assert_incomplete()

    def test_protected_token_file_and_unsafe_origins(self):
        path = Path(self.temporary.name) / 'token'
        path.write_text(TOKEN + '\n')
        path.chmod(0o600)
        self.assertEqual(TOKEN, export.token_from_file(path))
        path.chmod(0o644)
        with self.assertRaisesRegex(export.ExportError, 'mode-0600'):
            export.token_from_file(path)
        for base in ('http://con.coflnet.com', 'https://user:password@con.coflnet.com',
                     'https://con.coflnet.com/path', 'https://con.coflnet.com?token=secret'):
            with self.subTest(base=base), self.assertRaises(export.ExportError):
                export.origin(base)
        for token in (TOKEN + '\r\n', 'x' * 513):
            with self.subTest(token_length=len(token)), self.assertRaises(export.ExportError):
                export.validate_token(token)


if __name__ == '__main__':
    unittest.main()
