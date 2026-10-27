// Run against a loopback release build; all account/API values are synthetic.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const assert = require('node:assert/strict');
const base = process.env.SYNC_TEST_BASE || 'http://127.0.0.1:4372';
if (!['127.0.0.1', 'localhost', '::1'].includes(new URL(base).hostname)) {
  throw Error('Only loopback test builds are permitted');
}
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
  let unavailable = true, requests = 0, requestAt;
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/sync/updates') {
      requests++;
      requestAt = Date.now();
      return route.fulfill(unavailable ? {
        status: 503, json: {slug: 'storage_unavailable', message: 'private synthetic details'},
      } : {json: {entries: [], latestVersion: 0}});
    }
    return route.fulfill({json: []});
  });
  await page.goto(base);
  await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.getByRole('button', {name: 'Sync now', exact: true}).first().click();
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
  await page.getByRole('button', {name: 'Unlock and sync', exact: true}).click();
  await page.getByText('Unlock encrypted sync', {exact: true}).waitFor({state: 'detached'});
  assert.equal(requests, 2);
  assert.equal(await retainedInput.evaluate(el => el.value === '' && !el.isConnected), true);
  console.log(JSON.stringify({width, clickToRequestMs, clickToErrorMs, domAutofill: true, focusRoundtrip: true, storageError: true, retainedPassword: true, retrySucceeded: true, passwordDomCleared: true}));
  await browser.close();
})().catch(async error => {
  console.error(error.stack);
  await browser?.close();
  process.exit(1);
});
