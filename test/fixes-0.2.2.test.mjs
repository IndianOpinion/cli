// Tests for the 0.2.2 fixes (22 October 2026): IndianOpinion/cli #17 to #22 and #24.
// Node CLI and io.sh against the REST stub; no network.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startStub, GOOD_TOKEN, EMAIL } from './stub-rest.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const BIN = path.join(ROOT, 'bin', 'indianopinion.mjs');
const IOSH = path.join(ROOT, 'io.sh');
const HAVE_CURL = spawnSync('bash', ['-c', 'command -v curl']).status === 0;
const HAVE_JQ = spawnSync('bash', ['-c', 'command -v jq']).status === 0;
let stub; let home;

function run(args, { env = {}, bin = 'node' } = {}) {
  const [cmd, argv] = bin === 'node' ? [process.execPath, [BIN, ...args]] : ['bash', [IOSH, ...args]];
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { env: { PATH: process.env.PATH, HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'), IO_API: stub.api, IO_TOKEN: GOOD_TOKEN, ...env } });
    let out = ''; let errs = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { errs += d; });
    child.stdin.end();
    child.on('close', (code) => {
      let json = null;
      try { json = JSON.parse(out); } catch { /* text */ }
      resolve({ code, out, err: errs, json });
    });
  });
}

before(async () => { stub = await startStub(); home = fs.mkdtempSync(path.join(os.tmpdir(), 'io-fix22-')); });
after(async () => { await stub.close(); });

const bins = () => ['node', ...(HAVE_CURL && HAVE_JQ ? ['bash'] : [])];

test('#18: <command> --help shows help and exits 0, in io.sh as in the CLI', { skip: !HAVE_CURL }, async () => {
  for (const args of [['briefs', '--help'], ['token', 'new', '--help'], ['prefs', 'set', '--help'], ['brief', '-h']]) {
    const r = await run(args, { bin: 'bash' });
    assert.equal(r.code, 0, `io.sh ${args.join(' ')}: ${r.err}`);
    assert.match(r.out, /io login start/);
  }
  assert.equal((await run(['briefs', '--help'])).code, 0);
});

test('#24: no arguments exits 2 in io.sh, as in the CLI', { skip: !HAVE_CURL }, async () => {
  const r = await run([], { bin: 'bash' });
  assert.equal(r.code, 2);
  assert.match(r.out, /io login start/);
  assert.equal((await run([])).code, 2);
});

test('#19: login start names the login verify command as the next step, not a REST POST', async () => {
  for (const bin of bins()) {
    const r = await run(['login', 'start', '--email', EMAIL], { bin, env: { IO_TOKEN: '' } });
    assert.equal(r.code, 0, `${bin}: ${r.err}`);
    const prefix = bin === 'node' ? 'indianopinion' : 'io';
    assert.equal(r.json.next[0].command, `${prefix} login verify --email ${EMAIL} --code <6 digits>`);
    assert.doesNotMatch(r.json.message, /POST/);
    assert.match(r.json.message, new RegExp(`${prefix} login verify`));
    assert.equal(r.json.unsubscribe, `${prefix} unsubscribe --what all --yes`);
  }
});

test('#20: topics unfollow takes the name or --key used to follow, and follow names the undo command', async () => {
  for (const bin of bins()) {
    let r = await run(['topics', 'follow', '--id', '88'], { bin });
    assert.equal(r.code, 0, `${bin} follow: ${r.err}`);
    if (bin === 'node') assert.ok(r.json.next.some((n) => n.command === 'indianopinion topics unfollow 88'), JSON.stringify(r.json.next));
    r = await run(['topics', 'unfollow', 'Supreme Court of India'], { bin });
    assert.equal(r.code, 0, `${bin} unfollow by name: ${r.err}`);
    assert.equal(r.json.removed, true, `${bin}: ${r.out}`);
    await run(['topics', 'follow', '--id', '88'], { bin });
    r = await run(['topics', 'unfollow', '--key', 't88'], { bin });
    assert.equal(r.code, 0, `${bin} unfollow --key: ${r.err}`);
    assert.equal(r.json.removed, true);
    r = await run(['topics', 'unfollow', 'no such topic'], { bin });
    assert.equal(r.code, 4, `${bin} unknown name`);
    r = await run(['topics', 'unfollow', '1', '2'], { bin });
    assert.equal(r.code, 2, `${bin} two ids`);
  }
});

test('#22: doctor on a fresh install without a token exits 0, still reporting the token as missing', async () => {
  for (const bin of bins()) {
    const r = await run(['doctor', '--json'], { bin, env: { IO_TOKEN: '' } });
    assert.equal(r.code, 0, `${bin}: ${r.out}`);
    assert.equal(r.json.signed_in, false);
    const t = r.json.checks.find((c) => c.name === 'token');
    assert.equal(t.ok, false);
    assert.equal(t.required, false);
  }
});

test('#17: the #14 regression test asks for the TAP reporter, so Node 24 passes too', () => {
  const t = fs.readFileSync(path.join(HERE, 'fixes.test.mjs'), 'utf8');
  assert.match(t, /--test-reporter=tap/);
});
