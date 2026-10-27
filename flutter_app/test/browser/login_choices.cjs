// Run after flutter build web --release. Serves local assets at the registered
// Con origin; only anonymous GETs reach production. Google is intercepted.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const origin = 'https://con.coflnet.com';
const issuer = 'https://auth.coflnet.com/auth/realms/con';
const build = path.resolve(__dirname, '../../build/web');
const output = path.resolve(process.env.LOGIN_CHOICES_OUTPUT ||
  path.join(__dirname, '../../../../reports/shared-identity-20261026/login-choices-20261027'));
fs.mkdirSync(output, {recursive: true, mode: 0o700});
fs.chmodSync(output, 0o700);
const mime = {'.html': 'text/html', '.js': 'application/javascript',
  '.json': 'application/json', '.wasm': 'application/wasm', '.css': 'text/css',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ttf': 'font/ttf',
  '.otf': 'font/otf', '.woff2': 'font/woff2', '.bin': 'application/octet-stream'};
const labels = locale => locale.startsWith('de') ? {
  google: 'Mit Google fortfahren', email: 'Mit E-Mail anmelden',
  create: 'Konto mit E-Mail erstellen', guest: 'Ohne Konto fortfahren',
  hint: 'Mit deinem Google-Konto kannst du dich anmelden oder ein Konto erstellen.',
} : {google: 'Continue with Google', email: 'Sign in with email',
  create: 'Create an account with email', guest: 'Continue without account',
  hint: 'Use your Google account to sign in or create an account.'};
let browser;
let stage = 'startup';
let lastEvidence;
const results = [];
async function session(locale, viewport, textScale = 1, configFailure = false) {
  const context = await browser.newContext({locale, viewport, serviceWorkers: 'block'});
  const evidence = lastEvidence = {authorization: null, google: false, configReads: 0, forbidden: [], hops: []};
  await context.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    try {
    if (request.method() !== 'GET') {
      evidence.forbidden.push('non-GET');
      return route.abort();
    }
    if (url.origin === origin) {
      if (url.pathname === '/api/auth/config') {
        evidence.configReads++;
        if (configFailure) return route.fulfill({status: 503, json: {}});
        const response = await route.fetch({maxRedirects: 0});
        const config = await response.json();
        assert.equal(config.enabled, true);
        assert.equal(config.issuer, issuer);
        assert.equal(config.clientId, 'con-app');
        return route.fulfill({response});
      }
      if (url.pathname.startsWith('/api/')) {
        evidence.forbidden.push('unapproved API');
        return route.abort();
      }
      const file = path.resolve(build, '.' + decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
      assert.ok(file.startsWith(build + path.sep), 'Asset path escapes build');
      if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return route.fulfill({status: 404, body: ''});
      const contentType = mime[path.extname(file)] || 'application/octet-stream';
      if (file.endsWith('/index.html') && textScale !== 1) {
        // Flutter engine findBrowserTextScaleFactor reads root computed font-size / 16.
        const body = fs.readFileSync(file, 'utf8').replace('</head>',
          `<style>html {font-size: ${16 * textScale}px;}</style></head>`);
        return route.fulfill({body, contentType});
      }
      return route.fulfill({path: file, contentType});
    }
    if (url.origin === new URL(issuer).origin &&
        (url.pathname.startsWith('/auth/realms/con/') || url.pathname.startsWith('/auth/resources/'))) {
      if (url.pathname === new URL(issuer).pathname + '/protocol/openid-connect/auth') {
        const query = url.searchParams;
        assert.equal(query.get('client_id'), 'con-app');
        assert.equal(query.get('redirect_uri'), origin + '/');
        assert.equal(query.get('response_type'), 'code');
        assert.equal(query.get('code_challenge_method'), 'S256');
        assert.match(query.get('code_challenge'), /^[A-Za-z0-9_-]{43}$/);
        assert.match(query.get('state'), /^[A-Za-z0-9_-]{43}$/);
        assert.equal(query.get('ui_locales'), locale.slice(0, 2));
        evidence.authorization = {hint: query.get('kc_idp_hint'),
          prompt: query.get('prompt'), pkce: true, state: true,
          locale: query.get('ui_locales'), callback: origin + '/'};
      }
      // Redirect chains can retain Playwright's original routing decision.
      // Follow at most five internal identity hops ourselves; never fetch Google.
      let next = url;
      for (let hop = 0; hop < 5; hop++) {
        evidence.hops.push({path: next.pathname, status: 'pending'});
        const response = await context.request.get(next.href,
          {maxRedirects: 0, timeout: 10000});
        evidence.hops.at(-1).status = response.status();
        const location = response.headers().location;
        if (!location) return route.fulfill({response});
        const destination = new URL(location, next);
        evidence.hops.at(-1).destination = destination.origin + destination.pathname;
        if (destination.origin === 'https://accounts.google.com') {
          assert.equal(destination.searchParams.get('redirect_uri'), issuer + '/broker/google/endpoint');
          assert.ok(destination.searchParams.get('client_id'));
          assert.deepEqual(destination.searchParams.getAll('prompt'), ['select_account']);
          assert.ok(['openid', 'profile', 'email'].every(scope =>
            destination.searchParams.get('scope').split(' ').includes(scope)));
          evidence.google = true;
          return route.fulfill({contentType: 'text/html', body: '<p>Google redirect safely intercepted.</p>'});
        }
        assert.equal(destination.origin, new URL(issuer).origin);
        assert.ok(destination.pathname.startsWith('/auth/realms/con/'));
        next = destination;
      }
      throw Error('Too many identity redirects');
    }
    if (url.origin === 'https://accounts.google.com') {
      evidence.forbidden.push('unexpected Google navigation');
      return route.abort();
    }
    if (request.isNavigationRequest()) evidence.forbidden.push('unapproved navigation');
    else evidence.blockedResources = [...new Set([...(evidence.blockedResources || []), url.origin])];
    return route.abort();
    } catch {
      evidence.forbidden.push('request contract failed');
      await route.abort().catch(() => {});
    }
  });
  const page = await context.newPage();
  await page.goto(origin + '/', {waitUntil: 'domcontentloaded'});
  await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
  await page.getByRole('button', {name: labels(locale).google, exact: true}).waitFor();
  return {context, page, evidence};
}
async function screenshot(page, name) {
  const file = path.join(output, name + '.png');
  await page.screenshot({path: file});
  fs.chmodSync(file, 0o600);
}
async function choices(page, locale, name, viewport, scale) {
  const text = labels(locale);
  await page.getByText(text.hint, {exact: true}).waitFor();
  for (const label of [text.google, text.email, text.create, text.guest]) {
    const button = page.getByRole('button', {name: label, exact: true});
    await button.scrollIntoViewIfNeeded();
    await button.focus();
    assert.ok(await button.evaluate(el => el === document.activeElement));
    const box = await button.boundingBox();
    assert.ok(box && box.x >= -1 && box.x + box.width <= viewport.width + 1,
      'Choice must fit viewport');
    assert.ok(box.y >= -1 && box.y + box.height <= viewport.height + 1,
      'Choice must be reachable vertically');
    await screenshot(page, `${name}-${label === text.google ? 'google' : label === text.email ? 'email' : label === text.create ? 'create' : 'guest'}`);
  }
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  if (scale === 2) assert.equal(await page.evaluate(() =>
    getComputedStyle(document.documentElement).fontSize), '32px');
  // Verify keyboard navigation actually moves focus after explicit button focus.
  await page.getByRole('button', {name: text.google, exact: true}).focus();
  await page.keyboard.press('Tab');
  assert.ok(await page.getByRole('button', {name: text.email, exact: true})
    .evaluate(el => el === document.activeElement));
}
(async () => {
  assert.ok(fs.existsSync(path.join(build, 'main.dart.js')), 'Build release web first');
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM || '/usr/bin/chromium',
    headless: true, args: ['--no-sandbox']});
  for (const locale of (process.env.LOGIN_CHOICES_FOCUS ? ['en-GB'] : ['en-GB', 'de-DE'])) {
    for (const [name, viewport, scale] of [
      ['desktop', {width: 1440, height: 1000}, 1],
      ['mobile', {width: 390, height: 844}, 1],
      ['landscape', {width: 844, height: 390}, 1],
      ['text200', {width: 390, height: 844}, 2],
    ].filter(() => !process.env.LOGIN_CHOICES_FOCUS)) {
      stage = `${locale}-${name}`;
      const {context, page, evidence} = await session(locale, viewport, scale);
      await choices(page, locale, `${locale}-${name}`, viewport, scale);
      assert.deepEqual(evidence.forbidden, []);
      results.push({locale, layout: name, textScale: scale, choicesReachable: true,
        keyboardFocus: true, noDocumentOverflow: true});
      await context.close();
    }
    for (const action of (process.env.LOGIN_CHOICES_FOCUS ? [process.env.LOGIN_CHOICES_FOCUS] : ['google', 'email', 'create', 'dialogGoogle'])) {
      stage = `${locale}-${action}`;
      const {context, page, evidence} = await session(locale, {width: 390, height: 844});
      const text = labels(locale);
      if (action === 'dialogGoogle') {
        await page.getByRole('button', {name: text.guest, exact: true}).click();
        await page.getByRole('button', {name: locale.startsWith('de') ? 'Einstellungen' : 'Settings', exact: true}).click();
        await page.getByText(locale.startsWith('de') ? /^Jetzt abgleichen/ : /^Force Sync\b/).click();
        await page.getByText(text.hint, {exact: true}).waitFor();
        await screenshot(page, `${locale}-account-dialog`);
      }
      await page.getByRole('button', {name: text[action === 'dialogGoogle' ? 'google' : action], exact: true}).click();
      if (action === 'google' || action === 'dialogGoogle') {
        await page.getByText('Google redirect safely intercepted.', {exact: true}).waitFor();
        assert.equal(evidence.authorization.hint, 'google');
        assert.equal(evidence.authorization.prompt, null);
        assert.equal(evidence.google, true);
      } else {
        await page.locator(action === 'create' ? '#kc-register-form' : '#kc-form-login').waitFor();
        assert.equal(await page.locator('html').getAttribute('lang'), locale.slice(0, 2));
        assert.equal(evidence.authorization.hint, '');
        assert.equal(evidence.authorization.prompt, action === 'create' ? 'create' : null);
        assert.equal(evidence.google, false);
        await screenshot(page, `${locale}-${action}-central-form`);
      }
      assert.deepEqual(evidence.forbidden, []);
      results.push({locale, action, ...evidence.authorization, googleIntercepted: evidence.google});
      await context.close();
    }
  }
  const {context, page, evidence} = await session('en-GB', {width: 390, height: 844}, 1, true);
  await page.getByRole('button', {name: labels('en').google, exact: true}).click();
  await page.getByText('Account sign-in is temporarily unavailable', {exact: false}).waitFor();
  assert.equal(evidence.authorization, null);
  assert.equal(evidence.configReads, 1);
  assert.ok(await page.getByRole('button', {name: labels('en').email, exact: true}).isDisabled());
  assert.ok(await page.getByRole('button', {name: labels('en').create, exact: true}).isDisabled());
  assert.ok(await page.getByRole('button', {name: labels('en').guest, exact: true}).isEnabled());
  await screenshot(page, 'config-unavailable');
  results.push({action: 'config-unavailable', staysInApp: true, noAuthorization: true});
  await context.close();
  await browser.close();
  fs.rmSync(path.join(output, 'failure.png'), {force: true});
  fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({issuer,
    actualGoogleContact: false, authenticated: false, results}, null, 2) + '\n', {mode: 0o600});
  console.log(JSON.stringify({passed: results.length, output}));
})().catch(async () => {
  // No exception URLs, callbacks, state, authorization codes, or private logs.
  console.error(JSON.stringify({failedStage: stage, evidence: lastEvidence}));
  const failedPage = browser?.contexts()[0]?.pages()[0];
  if (failedPage) await screenshot(failedPage, 'failure').catch(() => {});
  await browser?.close();
  process.exitCode = 1;
});
