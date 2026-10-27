// Run against an isolated loopback release build. Every API value is synthetic.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {DatabaseSync} = require('node:sqlite');
const base = process.env.SYNC_TEST_BASE || 'http://127.0.0.1:4372';
assert.ok(['127.0.0.1', 'localhost', '::1'].includes(new URL(base).hostname));
const password = 'synthetic-packed-password';
const salt = 'synthetic-packed-salt';
const key = crypto.pbkdf2Sync(password, 'con:encryption:v1:' + salt, 600000, 32, 'sha256');
const stamp = '2026-10-27T00:00:00.000Z';
const person = id => ({id, name: `Synthetic ${id}`, createdAt: stamp, updatedAt: stamp});
const local = [0, 1, 2].map(i => ({...person(`local-${i}`), isDeleted: i === 2}));
const remote = [0, 1, 2, 3].map(i => person(`remote-${i}`));
function encrypt(value) {
  const nonce = crypto.randomBytes(12), cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.from('con:v1:'));
  return 'con:v1:' + Buffer.concat([nonce, cipher.update(JSON.stringify(value)), cipher.final(), cipher.getAuthTag()]).toString('base64');
}
function decrypt(value) {
  assert.ok(value.startsWith('con:v1:'));
  const data = Buffer.from(value.slice(7), 'base64');
  const cipher = crypto.createDecipheriv('aes-256-gcm', key, data.subarray(0, 12));
  cipher.setAAD(Buffer.from('con:v1:'));
  cipher.setAuthTag(data.subarray(-16));
  return Buffer.concat([cipher.update(data.subarray(12, -16)), cipher.final()]).toString();
}
// Reuse the app-created SQLite schema; edit only this fresh context's synthetic
// database while the app is unloaded. IndexedDbFileSystem uses 4096-byte blocks.
async function readDatabase(page) {
  return page.evaluate(async () => {
    const request = indexedDB.open('sqflite_databases');
    const db = await new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    const tx = db.transaction(['files', 'blocks']);
    const read = request => new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    const [files, ids, blocks, keys] = await Promise.all([
      read(tx.objectStore('files').getAll()), read(tx.objectStore('files').getAllKeys()),
      read(tx.objectStore('blocks').getAll()), read(tx.objectStore('blocks').getAllKeys()),
    ]);
    const index = files.findIndex(file => file.name.endsWith('relationship_manager.db'));
    if (index < 0) throw Error('Synthetic SQLite file missing');
    const bytes = new Uint8Array(files[index].length);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i][0] !== ids[index]) continue;
      const data = new Uint8Array(blocks[i] instanceof Blob ? await blocks[i].arrayBuffer() : blocks[i]);
      bytes.set(data.subarray(0, Math.min(data.length, bytes.length - keys[i][1])), keys[i][1]);
    }
    db.close();
    return {id: ids[index], name: files[index].name, bytes: Array.from(bytes)};
  });
}
async function seedPending(page, directory) {
  const file = await readDatabase(page);
  await page.route('**/__packed_seed__', route => route.fulfill({contentType: 'text/html', body: 'Synthetic database preparation'}));
  await page.goto(new URL('/__packed_seed__', base).href);
  const sqlitePath = path.join(directory, 'synthetic.db');
  fs.writeFileSync(sqlitePath, Buffer.from(file.bytes), {mode: 0o600});
  const db = new DatabaseSync(sqlitePath);
  for (const value of local) {
    const data = JSON.stringify(value);
    db.prepare('INSERT INTO persons (id,data,version,created_at,updated_at,is_deleted) VALUES (?,?,0,?,?,?)')
      .run(value.id, data, stamp, stamp, Number(value.isDeleted));
    db.prepare('INSERT INTO pending_changes (id,entity_type,entity_id,operation,data,created_at,synced) VALUES (?,?,?,?,?,?,0)')
      .run('pending-' + value.id, 'person', value.id, 'create', data, stamp);
  }
  db.close();
  await page.evaluate(async ({id, name, bytes}) => {
    const request = indexedDB.open('sqflite_databases');
    const db = await new Promise(resolve => { request.onsuccess = () => resolve(request.result); });
    const tx = db.transaction(['files', 'blocks'], 'readwrite');
    tx.objectStore('files').put({name, length: bytes.length}, id);
    tx.objectStore('blocks').delete(IDBKeyRange.bound([id, 0], [id, Number.MAX_SAFE_INTEGER]));
    const data = new Uint8Array(bytes);
    for (let offset = 0; offset < data.length; offset += 4096) {
      const block = new Uint8Array(4096);
      block.set(data.subarray(offset, offset + 4096));
      tx.objectStore('blocks').put(block.buffer, [id, offset]);
    }
    await new Promise((resolve, reject) => { tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); });
    db.close();
  }, {id: file.id, name: file.name, bytes: Array.from(fs.readFileSync(sqlitePath))});
}
let browser;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'con-packed-browser-'));
(async () => {
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM || '/usr/bin/chromium',
    headless: true, args: ['--no-sandbox']});
  const context = await browser.newContext({locale: 'en-GB', viewport: {width: 1440, height: 1000}, serviceWorkers: 'block'});
  await context.route('**/*', route => new URL(route.request().url()).origin === new URL(base).origin ? route.continue() : route.abort());
  await context.addInitScript(({salt}) => {
    localStorage.setItem('flutter.auth_token', JSON.stringify('synthetic-packed-token'));
    localStorage.setItem('flutter.user_id', JSON.stringify('synthetic-packed-user'));
    localStorage.setItem('flutter.encryption_salt', JSON.stringify(salt));
    window.packedCrypto = {encrypt: 0, decrypt: 0};
    for (const operation of ['encrypt', 'decrypt']) {
      const original = crypto.subtle[operation].bind(crypto.subtle);
      crypto.subtle[operation] = (...args) => { window.packedCrypto[operation]++; return original(...args); };
    }
  }, {salt});
  const page = await context.newPage();
  let updates = 0, downloads = 0, uploads = 0, legacyIndexes = 0, routeError;
  await page.route('**/api/**', async route => {
    try {
      const endpoint = new URL(route.request().url()).pathname;
      const body = route.request().postDataJSON();
      if (endpoint === '/api/auth/me') return route.fulfill({json: {
        id: 'synthetic-packed-user', encryptionKeySalt: salt,
      }});
      if (endpoint === '/api/sync/updates') {
        updates++;
        return route.fulfill({json: {entries: remote.map((value, i) => ({blobType: 'person', blobId: value.id,
          version: i + 1, s3Key: 'synthetic/' + value.id})), latestVersion: 4,
          batching: {version: 1, maxEntries: 128, maxPayloadBytes: 4194304, canUploadPacks: true}}});
      }
      if (endpoint === '/api/sync/download/batch') {
        downloads++;
        assert.equal(body.entries.length, 4);
        return route.fulfill({json: {entries: body.entries.map(entry => ({...entry, version: 1,
          ...(entry.blobId === 'remote-3' ? {isDeleted: true} : {data: encrypt(remote.find(value => value.id === entry.blobId))})}))}});
      }
      if (endpoint === '/api/sync/upload/batch') {
        uploads++;
        assert.equal(body.entries.length, 3);
        for (const entry of body.entries) {
          const plain = decrypt(entry.data), value = JSON.parse(plain);
          assert.deepEqual(value, local.find(item => item.id === entry.blobId));
          assert.equal(entry.blobType, 'person');
          assert.equal(entry.isDeleted, value.isDeleted);
          assert.equal(entry.checksum, crypto.createHash('sha256').update(plain).digest('hex'));
        }
        return route.fulfill({json: {}});
      }
      if (endpoint === '/api/sync/upload') {
        assert.equal(body.blobType, 'index');
        legacyIndexes++;
        return route.fulfill({json: {uploadUrl: new URL('/__packed_index__', base).href, s3Key: 'synthetic/index'}});
      }
      if (endpoint === '/api/sync/commit') {
        assert.equal(body.blobType, 'index');
        return route.fulfill({json: {}});
      }
      throw Error('Unexpected synthetic API operation: ' + endpoint);
    } catch (error) { routeError = error; await route.abort(); }
  });
  await page.route('**/__packed_index__', route => {
    assert.equal(route.request().method(), 'PUT');
    assert.equal(typeof JSON.parse(decrypt(route.request().postData())).lastSyncTimestamp, 'number');
    return route.fulfill({json: {}});
  });
  async function load() {
    await page.goto(base);
    await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
    await page.getByRole('button', {name: 'Settings', exact: true}).waitFor();
  }
  await load();
  await seedPending(page, directory);
  await load();
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  await page.getByText(/^Force Sync\b/).click();
  const input = page.locator('input[type="password"][autocomplete="current-password"]');
  await input.fill('synthetic-wrong-password');
  await page.getByRole('button', {name: 'Unlock and sync', exact: true}).click();
  await page.getByText('Could not unlock and sync.', {exact: false}).waitFor();
  assert.equal(uploads, 0);
  assert.equal(legacyIndexes, 0);
  await input.fill(password);
  await page.getByRole('button', {name: 'Unlock and sync', exact: true}).click();
  await page.getByText('Unlock encrypted sync', {exact: true}).waitFor({state: 'detached'});
  await page.getByText('Sync complete', {exact: true}).waitFor();
  if (routeError) throw routeError;
  assert.equal(updates, 2);
  assert.equal(downloads, 2);
  assert.equal(uploads, 1);
  assert.equal(legacyIndexes, 1);
  const operations = await page.evaluate(() => window.packedCrypto);
  assert.ok(operations.encrypt >= 4 && operations.decrypt >= 4);
  const persisted = await readDatabase(page);
  const persistedPath = path.join(directory, 'persisted.db');
  fs.writeFileSync(persistedPath, Buffer.from(persisted.bytes), {mode: 0o600});
  const verified = new DatabaseSync(persistedPath);
  for (const value of remote.slice(0, 3)) {
    const row = verified.prepare('SELECT data,is_deleted FROM persons WHERE id=?').get(value.id);
    assert.equal(JSON.parse(row.data).name, value.name);
    assert.equal(row.is_deleted, 0);
  }
  assert.equal(verified.prepare('SELECT COUNT(*) AS n FROM persons WHERE id=?').get(remote[3].id).n, 0);
  assert.equal(verified.prepare('SELECT is_deleted FROM persons WHERE id=?').get(local[2].id).is_deleted, 1);
  assert.equal(verified.prepare('SELECT COUNT(*) AS n FROM pending_changes').get().n, 0);
  verified.close();
  console.log(JSON.stringify({downloadedRecords: 4, requestsPerDownload: 1, uploadedRecords: 3,
    metadataUploadRequests: uploads, wrongPasswordNoUpload: true, tombstones: true,
    webCrypto: operations, conV1NodeInteroperability: true, progressCompleted: true}));
  await browser.close();
})().catch(async error => {
  console.error(error.stack);
  await browser?.close();
  process.exitCode = 1;
}).finally(() => fs.rmSync(directory, {recursive: true, force: true}));
