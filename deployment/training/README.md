# Con training sample review

Training submissions require explicit consent, version `1`. The app submits only
the selected recording, the complete story text (typed notes and all transcripts
in that story), source-scoped people/connections and an optional correction. Reports without a recording retain metadata only.
Live ASR does not automatically retain recordings or create training submissions.
The people snapshot contains extracted names, company and facts; it does not copy
owner contact details from the address book. Anonymous submission is limited to
10 reports per effective IP per UTC day. Audio is limited to 10 MiB and ten minutes, transcript to
32,000 characters and correction to 4,000 characters. Total submission metadata
is limited to 64 KiB.

Reviewers use a separate `X-Training-Token` credential. Ordinary account JWTs do
not grant reviewer read/delete access. The backend stores only the SHA-256 digest
in `TrainingSamples:ReviewerTokenHash`. The raw reviewer credential is 32–512 printable ASCII characters
without whitespace and stays in an operator-owned mode-0600 file and must never appear in logs, URLs or command
arguments. The Con infrastructure helper
`ansible/scripts/provision-con-training.sh` accepts a protected token-file path;
it installs only that digest using the existing protected
`fleet/openbao/scripts/openbao-local-session.sh` flow. The predecessor `eu-cluster`
init authority only mints a narrow, short-lived, nonrenewable child. That child
reads the current Con-only KV leaf and patches the required field using CAS,
then is revoked, proved invalid and its token artifact removed. Existing fields
are preserved and an existing reviewer credential is not implicitly rotated.

Use Python 3.9+ with the standard library. The default origin is
`https://con.coflnet.com`; HTTPS certificate verification remains enabled and
redirects are refused. Requests identify themselves as `ConTrainingExport/1.0`.
HTTP is accepted only for loopback tests. Environment HTTP(S) proxies are honored;
use `--no-proxy` for a direct connection.

```sh
python3 deployment/training/export.py \
  --date 2026-10-04 \
  --output-dir /tmp/con-training-2026-10-04 \
  --token-file /run/media/ekwav/Data/dev/ansible/out/con-training/reviewer-token
```

`--date` selects a UTC day. Add `--sample-id <lowercase-UUID>` to export only a
known submission, such as an owned synthetic test sample. Other samples are not
written to disk; pagination stops once the selected sample is found. A missing
sample fails, and the manifest includes `sampleId` to distinguish a selected
export from a complete day. `--output-dir` must not exist; use a fresh directory
for every attempt. Its parent must already exist. `CON_TRAINING_TOKEN` is an
alternative when no token file is supplied; keep that environment private and
do not type secrets in shell command arguments. The script never prints a token,
response body or sample content. Failures report a static API path/status or a
fixed validation error.

The export follows `GET /api/training-samples?date=YYYY-MM-DD&limit=20&cursor=...`
and writes one `<id>.json` file per sample, preserving the returned metadata
(including `consentVersion` and `dataSha256`). Samples with audio also get
`<id>.wav`, fetched from `GET /api/training-samples/{date}/{id}/audio`. Metadata-only
samples have `audioSize: 0`, `audioSha256: null` and no WAV file. App reports use unknown captured language (`language: null`) because recording
language is not saved with the audio. Current settings do not label past recordings. The backend accepts
only explicitly consented submissions; the exporter requires consent version `1`.
Export directories are mode 0700 and files are mode 0600. Audio downloads are
bounded to 10 MiB, checked against declared bytes and SHA-256, validated as PCM
WAV, then atomically renamed. Invalid IDs/dates, duplicate IDs and repeated
pagination cursors fail. Metadata pages are bounded to 4 MiB and exports to
10,000 pages to prevent unbounded requests.

`manifest.json` starts with `completed: false`. Require process exit zero and
`completed: true` before treating an export as complete. A partial export retains
that false receipt; temporary downloads are removed. A rerun never overwrites
existing exports. Store these consented recordings and transcripts as sensitive
review data in an operator-controlled location and remove them when review is
finished. No production or owner data is needed for the local checks:

```sh
python3 -m unittest discover -s deployment/training -v
```

For explicit server-side cleanup, the reviewer API also accepts authenticated
`DELETE /api/training-samples/{date}/{id}` and returns HTTP 204. Deletion removes
that sample's metadata and recording. The export script performs read requests
only and never deletes source samples.
