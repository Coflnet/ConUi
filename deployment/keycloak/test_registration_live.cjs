// Use only a disposable loopback Keycloak realm configured by registration.py.
// Test-created users disappear when the disposable server is removed.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const assert = require('node:assert/strict');
const base = process.env.KEYCLOAK_TEST_BASE || 'http://127.0.0.1:18761';
if (!['127.0.0.1', 'localhost', '::1'].includes(new URL(base).hostname)) throw Error('Disposable loopback Keycloak required');
const callback = 'http://127.0.0.1:18762/';
const realms = (process.env.KEYCLOAK_TEST_REALMS || 'con').split(',');
if (realms.some(realm => !['con', 'wald', 'vereiner', 'rfind'].includes(realm))) throw Error('Only application test realms supported');
const password = 'SyntheticRegistration-password123!';
let browser;
async function registration({realm, locale = 'en', javaScriptEnabled = true} = {}) {
  const context = await browser.newContext({locale, javaScriptEnabled, viewport: {width: 390, height: 844}});
  await context.route(callback + '**', route => route.fulfill({body: 'Synthetic registration complete'}));
  const page = await context.newPage();
  const params = new URLSearchParams({client_id: 'con-app', redirect_uri: callback, response_type: 'code', scope: 'openid', code_challenge: 'a'.repeat(43), code_challenge_method: 'S256', kc_locale: locale});
  await page.goto(base + '/realms/' + realm + '/protocol/openid-connect/registrations?' + params);
  await page.locator('#email').waitFor();
  if (realm !== 'con') {
    const stylesheet = page.locator(`link[rel=stylesheet][href*='${realm}'][href$='.css']`).last();
    assert.equal((await context.request.get(new URL(await stylesheet.getAttribute('href'), base).href)).status(), 200);
    const favicon = page.locator('link[rel*=icon]').first();
    assert((await favicon.getAttribute('href')).includes(realm + '.svg'));
    assert.equal((await context.request.get(new URL(await favicon.getAttribute('href'), base).href)).status(), 200);
  }
  return {context, page};
}
async function submit(page) {
  await page.locator('#password').fill(password);
  await page.locator('#password-confirm').fill(password);
  await page.locator('input[type=submit], button[type=submit]').click();
}
(async () => {
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM || '/usr/bin/chromium', headless: true, args: ['--no-sandbox']});
  for (const realm of realms) {
  {
    const {context, page} = await registration({realm});
    assert.equal(await page.locator('form > :first-child input').getAttribute('id'), 'email');
    await page.locator('#email').fill('alice12.smith34@example.test');
    assert.equal(await page.locator('#username').inputValue(), 'alice.smith');
    assert.equal(await page.locator('#firstName').inputValue(), 'Alice');
    assert.equal(await page.locator('#lastName').inputValue(), 'Smith');
    assert.equal(await page.locator('details').getAttribute('open'), null);
    await submit(page);
    await page.waitForURL(callback + '**');
    assert(await page.getByText('Synthetic registration complete').isVisible());
    await context.close();
  }
  {
    const {context, page} = await registration({realm, locale: 'de'});
    assert.equal(await page.locator('summary').textContent(), 'Profil bearbeiten');
    await page.locator('#email').fill('alice99.smith88@another.test');
    await submit(page);
    await page.locator('#username[aria-invalid=true]').waitFor();
    assert.notEqual(await page.locator('details').getAttribute('open'), null);
    assert.equal(await page.locator('#username').inputValue(), 'alice.smith');
    await page.locator('#username').fill('alice.smith2');
    await page.locator('#firstName').fill('');
    await page.locator('#lastName').fill('');
    assert.equal(await page.locator('#firstName').getAttribute('required'), null);
    assert.equal(await page.locator('#lastName').getAttribute('required'), null);
    await submit(page);
    await page.waitForURL(callback + '**');
    await context.close();
  }
  {
    const {context, page} = await registration({realm, javaScriptEnabled: false});
    assert.equal(await page.locator('details').count(), 0);
    await page.locator('#email').fill('nojs@example.test');
    await page.locator('#username').fill('nojs');
    assert(await page.locator('#firstName').isVisible());
    assert(await page.locator('#lastName').isVisible());
    await submit(page);
    await page.waitForURL(callback + '**');
    await context.close();
  }
  }
  await browser.close();
  console.log('Disposable Keycloak registration passed (' + realms.join(', ') + '): suggestions, preserved branding, collision recovery, optional blank names, no JavaScript.');
})().catch(async error => { console.error(error.stack); await browser?.close(); process.exitCode = 1; });
