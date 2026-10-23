// GET-only visual review through a verified private TLS forward. Never submits accounts.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const fs = require('node:fs');
const https = require('node:https');
const crypto = require('node:crypto');
const path = require('node:path');
const assert = require('node:assert/strict');
const ca = fs.readFileSync(process.env.KEYCLOAK_PREVIEW_CA || '/tmp/con-registration-ops/identity-ca.crt');
const output = process.env.KEYCLOAK_PREVIEW_OUTPUT || '/tmp/con-registration-preview';
fs.mkdirSync(output, {recursive: true, mode: 0o700});
const applications = [
  ['con', 'con-app', 'https://con.coflnet.com/'],
  ['wald', 'wald-app', 'https://wald.coflnet.com/api/auth/callback'],
  ['vereiner', 'vereiner-app', 'https://ver.coflnet.com/auth/callback'],
  ['rfind', 'rfind-app', 'https://app.rfind.de/'],
];
let browser;
async function verifiedGet(request) {
  const url = new URL(request.url());
  if (request.method() !== 'GET' || url.origin !== 'https://auth.coflnet.com' || !url.pathname.startsWith('/auth/')) throw Error('Preview permits only identity GET requests');
  return new Promise((resolve, reject) => {
    const connection = https.request({hostname: '127.0.0.1', port: 18443,
      servername: 'auth.coflnet.com', ca, rejectUnauthorized: true, method: 'GET',
      path: url.pathname + url.search,
      headers: {...request.headers(), host: 'auth.coflnet.com', 'accept-encoding': 'identity'},
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        const headers = {};
        for (const [name, value] of Object.entries(response.headers)) {
          if (value !== undefined && !['transfer-encoding', 'content-length'].includes(name)) headers[name] = Array.isArray(value) ? value.join('\n') : value;
        }
        resolve({status: response.statusCode, headers, body: Buffer.concat(chunks)});
      });
      response.on('error', reject);
    });
    connection.setTimeout(20000, () => connection.destroy(new Error('Verified identity GET timed out')));
    connection.on('error', reject);
    connection.end();
  });
}
(async () => {
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM || '/usr/bin/chromium', headless: true, args: ['--no-sandbox']});
  const results = [];
  for (const [realm, client, redirect] of applications) for (const locale of ['en', 'de']) {
    for (const [layout, width, scale] of [['phone', 390, 1], ['desktop', 1440, 1], ['zoom200', 195, 2]]) {
      const context = await browser.newContext({locale, viewport: {width, height: 900 / scale}, deviceScaleFactor: scale});
      const errors = [];
      await context.route('**/*', async route => {
        try {
          const response = await verifiedGet(route.request());
          if (response.status >= 400) throw Error('Verified identity GET returned HTTP ' + response.status);
          await route.fulfill(response);
        }
        catch (error) { errors.push(error.message); await route.abort(); }
      });
      const page = await context.newPage();
      const challenge = crypto.createHash('sha256').update('synthetic-get-only-registration-preview').digest('base64url');
      const params = new URLSearchParams({client_id: client, redirect_uri: redirect, response_type: 'code', scope: 'openid', code_challenge: challenge, code_challenge_method: 'S256', kc_locale: locale});
      const view = realm === 'rfind' ? 'auth' : 'registrations';
      await page.goto(`https://auth.coflnet.com/auth/realms/${realm}/protocol/openid-connect/${view}?${params}`, {waitUntil: 'networkidle'});
      await page.locator(realm === 'rfind' ? '#username' : '#email').waitFor();
      if (realm !== 'rfind') {
        await page.locator('#email').fill('preview12.person34@example.invalid');
        assert.equal(await page.locator('summary').textContent(), locale === 'de' ? 'Profil bearbeiten' : 'Edit profile');
        const username = page.locator('#username');
        if (await username.count()) assert.equal(await username.inputValue(), 'preview.person');
      }
      assert.deepEqual(errors, []);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      await page.screenshot({path: path.join(output, `${realm}-${locale}-${layout}.png`), fullPage: true});
      results.push({realm, locale, layout, overflow, screenshot: `${realm}-${locale}-${layout}.png`});
      await context.close();
    }
  }
  fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify(results, null, 2));
  await browser.close();
  console.log(JSON.stringify({screenshots: results.length, overflow: results.filter(result => result.overflow).map(({realm, locale, layout}) => ({realm, locale, layout})), tlsVerified: true, methods: ['GET']}));
})().catch(async error => { console.error(error.stack); await browser?.close(); process.exitCode = 1; });
