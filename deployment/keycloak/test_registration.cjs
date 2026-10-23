// Real Chromium DOM checks; all addresses and submitted data are synthetic fixtures.
// PLAYWRIGHT_MODULE=/path/to/@playwright/test node deployment/keycloak/test_registration.cjs
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname, 'themes/con-registration/login/resources/js/registration.js'), 'utf8');
let browser;
const value = (page, id) => page.locator(`#${id}`).inputValue();
const group = (id, attrs = '') => `<div class="pf-v5-c-form__group"><label for="${id}">${id}</label><input id="${id}" name="${id}" ${attrs}></div>`;
async function fixture(context, {lang = 'en', fields = ''} = {}) {
  const page = await context.newPage();
  await page.setContent(`<html lang="${lang}"><body><form id="kc-register-form">
    ${group('firstName')}${group('lastName')}${group('username', 'required')}${group('email', 'required')}
    ${group('password', 'type="password" required')}${group('password-confirm', 'type="password" required')}
    <button>Register</button></form><script>${fields}${script}</script></body></html>`);
  return page;
}
(async () => {
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM || '/usr/bin/chromium', headless: true, args: ['--no-sandbox']});
  const context = await browser.newContext();
  for (const lang of ['en', 'de-DE']) {
    const page = await fixture(context, {lang});
    assert.equal(await page.locator('form > :first-child input').getAttribute('id'), 'email');
    assert.equal(await page.locator('summary').textContent(), lang === 'en' ? 'Edit profile' : 'Profil bearbeiten');
    await page.locator('#email').fill('anna12.mueller3@example.test');
    assert.equal(await value(page, 'firstName'), 'Anna');
    assert.equal(await value(page, 'lastName'), 'Mueller');
    assert.equal(await value(page, 'username'), 'anna.mueller');
    assert.equal(await page.locator('details').getAttribute('open'), null);
    await page.locator('summary').click();
    await page.locator('#firstName').fill('Élodie');
    await page.locator('#lastName').fill('');
    await page.locator('#username').fill('chosen123');
    await page.locator('#email').fill('other.person9@example.test');
    assert.equal(await value(page, 'firstName'), 'Élodie');
    assert.equal(await value(page, 'lastName'), '');
    assert.equal(await value(page, 'username'), 'chosen123');
    await page.close();
  }
  {
    const page = await fixture(context);
    await page.locator('#email').fill('jean-paul2.o_neill+tag99@example.test');
    assert.equal(await value(page, 'firstName'), 'Jean-Paul');
    assert.equal(await value(page, 'lastName'), 'O Neill');
    assert.equal(await value(page, 'username'), 'jean-paul.o.neill');
    await page.locator('#email').fill('123.456@example.test');
    assert.equal(await value(page, 'username'), '');
    assert.equal(await value(page, 'firstName'), '');
    assert.equal(await value(page, 'lastName'), '');
    assert.notEqual(await page.locator('details').getAttribute('open'), null);
    await page.locator('summary').click();
    await page.locator('#password').fill('synthetic-password');
    await page.locator('#password-confirm').fill('synthetic-password');
    await page.getByRole('button', {name: 'Register'}).click();
    assert.notEqual(await page.locator('details').getAttribute('open'), null);
    await page.close();
  }
  {
    const page = await fixture(context, {fields: `
      document.getElementById('email').value='anna.smith@example.test';
      document.getElementById('username').value='submitted-user';
      document.getElementById('username').setAttribute('aria-invalid','true');
      document.getElementById('lastName').value='Submitted';`});
    assert.equal(await value(page, 'username'), 'submitted-user');
    assert.equal(await value(page, 'lastName'), 'Submitted');
    assert.equal(await value(page, 'firstName'), '');
    assert.notEqual(await page.locator('details').getAttribute('open'), null);
    assert.equal(await page.locator('#username').getAttribute('aria-invalid'), 'true');
    await page.close();
  }
  const withoutJs = await browser.newContext({javaScriptEnabled: false});
  const page = await fixture(withoutJs);
  assert.equal(await page.locator('details').count(), 0);
  for (const id of ['firstName', 'lastName', 'username', 'email', 'password']) assert(await page.locator(`#${id}`).isVisible());
  await browser.close();
  console.log('Registration DOM checks passed: English/German, Unicode/digits, manual/server values, invalid username, no JavaScript.');
})().catch(async error => { console.error(error.stack); await browser?.close(); process.exitCode = 1; });
