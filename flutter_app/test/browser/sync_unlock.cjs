// Run against a loopback release build; all account/API values are synthetic.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const base = process.env.SYNC_TEST_BASE || 'http://127.0.0.1:4372';
if (!['127.0.0.1', 'localhost', '::1'].includes(new URL(base).hostname)) {
  throw Error('Only loopback test builds are permitted');
}
const remotePerson = Buffer.from(JSON.stringify({
  id: 'perf-person', name: 'Synthetic large sync person', notes: 'x'.repeat(4 * 1024 * 1024),
  createdAt: '2026-10-27T00:00:00.000Z', updatedAt: '2026-10-27T00:00:00.000Z',
}));
const key = crypto.pbkdf2Sync('synthetic-generated-password',
  'con:encryption:v1:synthetic-review-salt', 600000, 32, 'sha256');
function encryptPerson(person) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.from('con:v1:'));
  return 'con:v1:' + Buffer.concat([
    nonce, cipher.update(person), cipher.final(), cipher.getAuthTag(),
  ]).toString('base64');
}
const encryptedPerson = encryptPerson(remotePerson);
const encryptedSecondPerson = encryptPerson(Buffer.from(JSON.stringify({
  id: 'progress-person', name: 'Synthetic progress person', notes: 'Small second item',
  createdAt: '2026-10-27T00:00:00.000Z', updatedAt: '2026-10-27T00:00:00.000Z',
})));
let browser;
(async () => {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM || '/usr/bin/chromium',
    headless: true, args: ['--no-sandbox'],
  });
  const width = Number(process.env.SYNC_TEST_WIDTH || 1440);
  const context = await browser.newContext({locale: 'en-GB', viewport: {width, height: 844}});
  await context.route('**/*', route =>
    new URL(route.request().url()).origin === new URL(base).origin
      ? route.continue() : route.abort());
  await context.addInitScript(() => {
    localStorage.setItem('flutter.auth_token', JSON.stringify('synthetic-review-token'));
    localStorage.setItem('flutter.user_id', JSON.stringify('synthetic-review-user'));
    localStorage.setItem('flutter.encryption_salt', JSON.stringify('synthetic-review-salt'));
  });
  const page = await context.newPage();
  let unavailable = true, requests = 0, blobDownloads = 0, requestAt;
  let releaseSecondTransfer;
  let secondTransfer = new Promise(resolve => { releaseSecondTransfer = resolve; });
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/sync/updates') {
      requests++;
      requestAt = Date.now();
      return route.fulfill(unavailable ? {
        status: 503, json: {slug: 'storage_unavailable', message: 'private synthetic details'},
      } : {json: {entries: [{blobType: 'person', blobId: 'perf-person',
        s3Key: 'synthetic/perf-person', version: 1},
          {blobType: 'person', blobId: 'progress-person', s3Key: 'synthetic/progress-person', version: 2},
          {blobType: 'recording_chunk_v1', blobId: 'orphan-chunk', s3Key: 'synthetic/orphan', version: 3},
        ], latestVersion: 3}});
    }
    if (path.startsWith('/api/sync/download/person/')) {
      return route.fulfill({json: {downloadUrl: new URL('/__synthetic_blob/' + path.split('/').pop(), base).href}});
    }
    return route.fulfill({json: []});
  });
  await page.route('**/__synthetic_blob/*', async route => {
    blobDownloads++;
    const second = new URL(route.request().url()).pathname.endsWith('/progress-person');
    if (second) await secondTransfer;
    return route.fulfill({contentType: 'text/plain', body: second ? encryptedSecondPerson : encryptedPerson});
  });
  await page.goto(base);
  await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  await page.getByText(/^Force Sync\b/).click();
  await page.getByText('Unlock encrypted sync', {exact: true}).waitFor();
  const password = page.locator('input[type="password"][autocomplete="current-password"]');
  await password.waitFor({state: 'attached'});
  assert.equal(await password.evaluate(el => !!el.closest('form')), true);
  // Model a password manager generating/filling through DOM input/change events,
  // including leaving the field to interact with its browser UI first.
  await password.evaluate(el => {
    el.blur();
    window.dispatchEvent(new Event('blur'));
  });
  await password.evaluate(el => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, 'synthetic-generated-password');
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    window.dispatchEvent(new Event('focus'));
    el.focus();
  });
  const started = Date.now();
  await page.getByRole('button', {name: 'Unlock and sync', exact: true}).click();
  await page.getByText('Sync storage is temporarily unavailable.', {exact: false}).waitFor();
  const clickToErrorMs = Date.now() - started;
  const clickToRequestMs = requestAt - started;
  assert.ok(clickToErrorMs < 5000, `Sync feedback took ${clickToErrorMs}ms`);
  assert.equal(requests, 1);
  assert.equal(await password.inputValue(), 'synthetic-generated-password');
  assert.equal(await page.getByText('private synthetic details', {exact: false}).count(), 0);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  assert.ok(await password.evaluate(el => el.getBoundingClientRect().right <= innerWidth));
  if (process.env.SYNC_TEST_SCREENSHOT) {
    await page.screenshot({path: process.env.SYNC_TEST_SCREENSHOT, fullPage: false});
  }
  const retainedInput = await password.elementHandle();
  unavailable = false;
  // Finish pre-existing font/layout work before measuring the complete retry.
  await page.evaluate(async () => {
    await document.fonts.ready;
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  await page.evaluate(() => {
    window.syncGap = {last: performance.now(), max: 0};
    window.syncGap.timer = setInterval(() => {
      const now = performance.now();
      window.syncGap.max = Math.max(window.syncGap.max, now - window.syncGap.last);
      window.syncGap.last = now;
    }, 10);
  });
  await page.getByRole('button', {name: 'Unlock and sync', exact: true}).click();
  await page.getByText('Downloading 1 of 2 items (50%)', {exact: true}).waitFor();
  await page.getByText(/About .* remaining in this step/).waitFor();
  assert.equal(await retainedInput.evaluate(el => el.isConnected && el.value === 'synthetic-generated-password'), true);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  if (process.env.SYNC_TEST_PROGRESS_SCREENSHOT) {
    await page.screenshot({path: process.env.SYNC_TEST_PROGRESS_SCREENSHOT, fullPage: false});
  }
  releaseSecondTransfer();
  await page.getByText('Unlock encrypted sync', {exact: true}).waitFor({state: 'detached'});
  const maxEventLoopGapMs = await page.evaluate(async () => {
    await new Promise(resolve => setTimeout(resolve, 30));
    clearInterval(window.syncGap.timer);
    return window.syncGap.max;
  });
  assert.ok(maxEventLoopGapMs < 500, `Large sync blocked browser for ${maxEventLoopGapMs}ms`);
  assert.equal(blobDownloads, 2);
  assert.equal(requests, 2);
  assert.equal(await retainedInput.evaluate(el => el.value === '' && !el.isConnected), true);
  // Already-unlocked manual sync also exposes real progress, including retry paths.
  await page.getByText('Sync complete', {exact: true}).waitFor({state: 'detached'});
  secondTransfer = new Promise(resolve => { releaseSecondTransfer = resolve; });
  await page.getByText(/^Force Sync\b/).click();
  await page.getByText('Downloading 1 of 2 items (50%)', {exact: true}).waitFor();
  assert.equal(await page.getByText('Unlock encrypted sync', {exact: true}).count(), 0);
  releaseSecondTransfer();
  await page.getByText('Sync complete', {exact: true}).waitFor();
  assert.equal(blobDownloads, 4);
  assert.equal(requests, 3);
  console.log(JSON.stringify({width, clickToRequestMs, clickToErrorMs, payloadBytes: remotePerson.length, maxEventLoopGapMs, domAutofill: true, focusRoundtrip: true, storageError: true, retainedPassword: true, retrySucceeded: true, actualPartialProgress: true, stepEstimate: true, orphanChunksExcluded: true, unlockedProgress: true, passwordDomCleared: true}));
  await browser.close();
})().catch(async error => {
  console.error(error.stack);
  await browser?.close();
  process.exit(1);
});
