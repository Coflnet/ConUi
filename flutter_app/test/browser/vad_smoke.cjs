// Real local Silero/ORT inference against a synthetic speech WAV, without a microphone.
// VAD_TEST_WAV points to DiaFlutter/example/test/fixtures/standard_german_tts.wav.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const fs = require('node:fs');
const base = process.env.VAD_TEST_BASE || 'http://127.0.0.1:4372';
if (!['127.0.0.1', 'localhost', '::1'].includes(new URL(base).hostname)) throw Error('Loopback build required');
const wav = fs.readFileSync(process.env.VAD_TEST_WAV);
if (wav.toString('ascii', 0, 4) !== 'RIFF' || wav.readUInt32LE(24) !== 16000 || wav.readUInt16LE(22) !== 1) throw Error('16kHz mono WAV required');
let offset = 12;
while (wav.toString('ascii', offset, offset + 4) !== 'data') offset += 8 + wav.readUInt32LE(offset + 4);
const samples = [];
for (let i = offset + 8; i + 1 < wav.length; i += 2) samples.push(wav.readInt16LE(i) / 32768);
let browser;
(async () => {
  browser = await chromium.launch({executablePath: '/usr/bin/chromium', headless: true, args: ['--no-sandbox']});
  const page = await browser.newPage();
  const external = [];
  await page.route('**/*', route => {
    if (new URL(route.request().url()).origin !== new URL(base).origin) { external.push(route.request().url()); return route.abort(); }
    return route.continue();
  });
  // Load only our locally shipped inference assets, independent of account setup.
  await page.goto(base + '/vad/README.md');
  await page.addScriptTag({url: base + '/vad/ort.wasm.min.js'});
  const result = await page.evaluate(async ({base, samples}) => {
    ort.env.wasm.wasmPaths = base + '/vad/';
    const began = performance.now();
    const session = await ort.InferenceSession.create(base + '/assets/packages/vad/companion-package/silero_vad_v5.onnx');
    let state = new ort.Tensor('float32', new Float32Array(256), [2, 1, 128]);
    const sr = new ort.Tensor('int64', BigInt64Array.from([16000n]), [1]);
    let speech = 0, silence = 0, redeemed = 0, ended = false;
    const inferenceStart = performance.now();
    const audio = [...samples, ...new Array(16000).fill(0)];
    for (let i = 0; i + 512 <= audio.length; i += 512) {
      const output = await session.run({input: new ort.Tensor('float32', Float32Array.from(audio.slice(i, i + 512)), [1, 512]), state, sr});
      state = output.stateN;
      const p = output.output.data[0];
      if (p >= .3) { speech++; redeemed = 0; }
      else if (p < .2) { silence++; if (speech > 0 && ++redeemed >= 16) ended = true; }
      else redeemed = 0;
    }
    await session.release();
    return {speechFrames: speech, silenceFrames: silence, speechEnd: ended, inferenceMs: Math.round(performance.now() - inferenceStart), totalMs: Math.round(performance.now() - began)};
  }, {base, samples});
  if (!result.speechFrames || !result.silenceFrames || !result.speechEnd || external.length) throw Error(JSON.stringify({result, external}));
  console.log(JSON.stringify({...result, externalRequests: external.length}));
  await browser.close();
})().catch(async error => { console.error(error.stack); await browser?.close(); process.exit(1); });
