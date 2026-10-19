// Tests for bin/indianopinion.mjs and io.sh against the REST stub. The MCP
// bridge test runs the io-mcp Worker module in a local HTTP server when the
// io-mcp Worker source is available: IO_MCP_DIR, or a sibling checkout of
// https://github.com/IndianOpinion/mcp at ../mcp (or ../io-mcp-worker), with
// its dependencies installed (npm ci there); otherwise that test is skipped.
//   node --test test/*.test.mjs

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { startStub, GOOD_TOKEN, GOOD_CODE, EMAIL } from './stub-rest.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BIN = path.join(HERE, '..', 'bin', 'indianopinion.mjs');
const IOSH = path.join(HERE, '..', 'io.sh');
let stub; let dead; let home;

function run(args, { env = {}, input, bin = 'node' } = {}) {
  // Async: the stub runs in this process, so a blocking spawnSync would deadlock it.
  const argv = bin === 'node' ? [BIN, ...args] : [IOSH, ...args];
  return new Promise((resolve) => {
    const child = spawn(bin === 'node' ? process.execPath : 'bash', argv, {
      env: { PATH: process.env.PATH, HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'), IO_API: stub.api, ...env },
    });
    let out = ''; let errs = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { errs += d; });
    if (input !== undefined) child.stdin.end(input); else child.stdin.end();
    child.on('close', (code) => {
      let json = null;
      try { json = JSON.parse(out); } catch { /* text */ }
      let errJson = null;
      try { errJson = JSON.parse(errs.trim().split('\n').pop()); } catch { /* text */ }
      resolve({ code, out, err: errs, json, errJson });
    });
  });
}

before(async () => {
  stub = await startStub();
  dead = await startStub({ agentLive: false });
  home = fs.mkdtempSync(path.join(os.tmpdir(), 'io-cli-'));
});
after(async () => { await stub.close(); await dead.close(); });

test('help, version and the machine-readable command list', async () => {
  let r = await run(['--version']);
  assert.equal(r.code, 0);
  assert.equal(r.json.version, '0.2.1');
  r = await run(['--help', '--json']);
  assert.equal(r.code, 0);
  assert.ok(r.json.commands.find((c) => c.cmd === 'mcp'));
  assert.equal(r.json.exit_codes.choice, 8);
  r = await run(['--help', '--text']);
  assert.match(r.out, /Exit codes/);
  r = await run(['nonsense']);
  assert.equal(r.code, 2);
  assert.equal(r.errJson.error, 'usage');
});

test('public commands need no token', async () => {
  let r = await run(['briefs', '--q', 'bengaluru metro']);
  assert.equal(r.code, 0, r.err);
  assert.equal(r.json.items.length, 1);
  assert.equal(r.json.items[0].post_id, 99812);
  r = await run(['briefs', '--limit', '2']);
  assert.equal(r.json.items.length, 2);
  assert.ok(r.json.next_cursor);
  const r2 = await run(['briefs', '--limit', '2', '--cursor', r.json.next_cursor]);
  assert.equal(r2.json.items[0].post_id, 99770);
  r = await run(['briefs', '--category', 'politics']);
  assert.equal(r.json.items.length, 2);
  r = await run(['brief', '99812']);
  assert.equal(r.code, 0);
  assert.equal(r.json.id, 99812);
  r = await run(['brief', `${stub.url}/story-99812/`, '--include', 'sources']);
  assert.equal(r.code, 0, r.err);
  assert.equal(r.json.sources.length, 3);
  assert.equal(r.json.analysis, undefined);
  r = await run(['brief', '1']);
  assert.equal(r.code, 4);
  r = await run(['brief', 'https://example.com/x/']);
  assert.equal(r.code, 6);
  r = await run(['brief', '99812', '--text']);
  assert.match(r.out, /^# Bengaluru Metro/);
});

test('login start and verify store the token with mode 0600', async () => {
  let r = await run(['login', 'start', '--email', EMAIL, '--name', 'Morning briefer']);
  assert.equal(r.code, 0, r.err);
  assert.equal(r.json.code_length, 6);
  assert.match(r.err, /daily digest and Breaking News/);
  assert.match(r.err, /unsubscribe --what all --yes/);
  r = await run(['login', 'start', '--email', 'nope']);
  assert.equal(r.code, 6);
  assert.equal(r.errJson.error, 'invalid_email');
  r = await run(['login', 'start', '--email', 'slow@agents.example.org']);
  assert.equal(r.code, 5);
  assert.equal(r.errJson.retry_after, 42);
  r = await run(['login', 'verify', '--email', EMAIL, '--code', '000000']);
  assert.equal(r.code, 6);
  assert.equal(r.errJson.attempts_left, 4);
  r = await run(['login', 'verify', '--email', EMAIL, '--code', GOOD_CODE]);
  assert.equal(r.code, 0, r.err);
  const f = path.join(home, '.config', 'indianopinion', 'token');
  assert.equal(fs.readFileSync(f, 'utf8').trim(), GOOD_TOKEN);
  assert.equal(fs.statSync(f).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(f)).mode & 0o777, 0o700);
  assert.equal(r.json.token_file, f);
});

test('account commands with the stored token', async () => {
  const cases = [
    [['me'], (j) => j.account.id === 1234],
    [['digest'], (j) => j.stories.length === 3],
    [['digest', '--date', '2026-10-02', '--limit', '1'], (j) => j.stories.length === 1],
    [['topics', 'list'], (j) => j.following.length >= 1],
    [['topics', 'follow', 'Supreme', 'Court', '--tier', 'instant'], (j) => j.ok],
    [['topics', 'unfollow', '412'], (j) => j.removed === true],
    [['breaking', 'status'], (j) => j.breaking.composite === 'mean'],
    [['breaking', 'set', '--threshold', '0.25', '--composite', 'breaking', '--max-per-day', '3'], (j) => j.preferences.breaking.threshold === 0.25],
    [['breaking', 'recent', '--days', '7'], (j) => j.events.length === 2],
    [['breaking', 'recent', '--would-send'], (j) => j.events.length === 1],
    [['breaking', 'show', '5531'], (j) => j.event_id === 5531],
    [['prefs', 'get'], (j) => j.preferences.digest.format === 'text'],
    [['prefs', 'set', '--format', 'json', '--hour', '12'], (j) => j.preferences.digest.hour_local === 12],
    [['token', 'list'], (j) => j.tokens.length >= 1],
    [['token', 'new', '--label', 'ci'], (j) => j.token.startsWith('ioa_')],
    [['token', 'revoke', 'a1b2c3d4e5f6', '--yes'], (j) => j.revoked === true],
    [['browser-link'], (j) => j.browser_url.includes('browser')],
    [['unsubscribe', '--what', 'digest', '--yes'], (j) => j.stopped.includes('digest')],
    [['whoami'], (j) => j.ok],
  ];
  for (const [args, check] of cases) {
    const r = await run(args);
    assert.equal(r.code, 0, `${args.join(' ')}: ${r.err}`);
    assert.ok(check(r.json), `${args.join(' ')} -> ${r.out.slice(0, 200)}`);
  }
  const sent = stub.requests.filter((q) => q.path.includes('/agent/me'));
  assert.equal(sent.at(-1).headers.authorization, `Bearer ${GOOD_TOKEN}`);
  assert.match(sent.at(-1).headers['user-agent'], /^indianopinion-cli\/0\.2\.1/);
});

test('exit codes: usage, validation, choice, auth, not found, network', async () => {
  let r = await run(['unsubscribe', '--what', 'digest']);
  assert.equal(r.code, 2, 'needs --yes');
  r = await run(['token', 'revoke', 'abc']);
  assert.equal(r.code, 2);
  r = await run(['breaking', 'set', '--threshold', '1.5']);
  assert.equal(r.code, 6);
  r = await run(['prefs', 'set', '--hour', '9']);
  assert.equal(r.code, 6);
  r = await run(['topics', 'follow', 'metro']);
  assert.equal(r.code, 8);
  assert.equal(r.errJson.options.length, 2);
  r = await run(['digest', '--date', '1999-01-01']);
  assert.equal(r.code, 4);
  r = await run(['me'], { env: { IO_TOKEN: 'ioa_000000000000_revokedrevokedrevoked' } });
  assert.equal(r.code, 3);
  assert.equal(r.errJson.error, 'invalid_token');
  r = await run(['me'], { env: { XDG_CONFIG_HOME: path.join(home, 'empty') } });
  assert.equal(r.code, 3);
  assert.equal(r.errJson.error, 'missing_token');
  r = await run(['me'], { env: { IO_API: dead.api } });
  assert.equal(r.code, 4);
  assert.match(r.errJson.message, /not answering yet/);
  r = await run(['briefs'], { env: { IO_API: 'http://127.0.0.1:9/wp-json/io/v1' } });
  assert.equal(r.code, 7);
});

test('IO_TOKEN is used with no token file, and wins over a bad file', async () => {
  const empty = path.join(home, 'empty2');
  let r = await run(['me'], { env: { IO_TOKEN: GOOD_TOKEN, XDG_CONFIG_HOME: empty } });
  assert.equal(r.code, 0, r.err);
  const bad = fs.mkdtempSync(path.join(os.tmpdir(), 'io-bad-'));
  fs.mkdirSync(path.join(bad, 'indianopinion'));
  fs.writeFileSync(path.join(bad, 'indianopinion', 'token'), 'ioa_000000000000_revokedrevokedrevoked\n');
  r = await run(['me'], { env: { XDG_CONFIG_HOME: bad } });
  assert.equal(r.code, 3);
  r = await run(['me'], { env: { XDG_CONFIG_HOME: bad, IO_TOKEN: GOOD_TOKEN } });
  assert.equal(r.code, 0);
});

test('skill install writes SKILL.md with frontmatter', async () => {
  const dir = path.join(home, 'skills');
  const r = await run(['skill', 'install', '--dir', dir]);
  assert.equal(r.code, 0, r.err);
  const md = fs.readFileSync(path.join(dir, 'indianopinion', 'SKILL.md'), 'utf8');
  assert.match(md, /^---\nname: indianopinion\ndescription: Use when/);
  const shipped = fs.readFileSync(path.join(HERE, '..', 'skill', 'SKILL.md'), 'utf8');
  assert.equal(md, shipped, 'skill/SKILL.md is the same text the CLI writes');
});

test('no em dash anywhere in the CLI, io.sh, SKILL.md or README', () => {
  for (const f of [BIN, IOSH, path.join(HERE, '..', 'skill', 'SKILL.md'), path.join(HERE, '..', 'README.md')]) {
    if (!fs.existsSync(f)) continue;
    assert.ok(!fs.readFileSync(f, 'utf8').includes('\u2014'), f);
  }
});

test('io.sh: same commands, exit codes and token file', async () => {
  if (spawnSync('bash', ['-c', 'command -v curl']).status !== 0) return;
  const h2 = fs.mkdtempSync(path.join(os.tmpdir(), 'io-sh-'));
  const env = { HOME: h2, XDG_CONFIG_HOME: path.join(h2, '.config') };
  let r = await run(['briefs', '--limit', '2'], { bin: 'bash', env });
  assert.equal(r.code, 0, r.err);
  assert.equal(r.json.items.length, 2);
  r = await run(['brief', '99812'], { bin: 'bash', env });
  assert.equal(r.json.id, 99812);
  r = await run(['me'], { bin: 'bash', env });
  assert.equal(r.code, 3);
  r = await run(['login', 'start', '--email', EMAIL, '--name', 'Quote " and \\ backslash'], { bin: 'bash', env });
  assert.equal(r.code, 0, r.err);
  const startBody = JSON.parse(stub.requests.filter((q) => q.path.endsWith('/agent/start')).at(-1).body);
  assert.equal(startBody.agent_name, 'Quote " and \\ backslash');
  r = await run(['login', 'verify', '--email', EMAIL, '--code', GOOD_CODE], { bin: 'bash', env });
  assert.equal(r.code, 0, r.err);
  const f = path.join(h2, '.config', 'indianopinion', 'token');
  assert.equal(fs.readFileSync(f, 'utf8').trim(), GOOD_TOKEN);
  assert.equal(fs.statSync(f).mode & 0o777, 0o600);
  for (const [args, check] of [
    [['me'], (j) => j.account.id === 1234],
    [['digest'], (j) => j.date === '2026-10-02'],
    [['digest', '--date', '2026-10-02'], (j) => j.ok],
    [['topics', 'list'], (j) => Array.isArray(j.following)],
    [['topics', 'follow', 'Supreme', 'Court', '--tier', 'instant'], (j) => j.ok],
    [['breaking', 'status'], (j) => j.ok && j.breaking.composite && j.sent_last_24h === 1],
    [['breaking', 'set', '--threshold', '0.4', '--composite', 'mean'], (j) => j.preferences.breaking.threshold === 0.4],
    [['breaking', 'recent', '--days', '3'], (j) => j.events.length === 2],
    [['breaking', 'show', '5531'], (j) => j.event_id === 5531],
    [['prefs', 'set', '--format', 'text', '--hour', '7', '--tz', 'Europe/London'], (j) => j.preferences.digest.tz === 'Europe/London'],
    [['token', 'list'], (j) => j.tokens.length >= 1],
    [['unsubscribe', '--what', 'breaking', '--yes'], (j) => j.stopped.includes('breaking')],
  ]) {
    r = await run(args, { bin: 'bash', env });
    assert.equal(r.code, 0, `io.sh ${args.join(' ')}: ${r.err}`);
    assert.ok(check(r.json), `io.sh ${args.join(' ')} -> ${r.out.slice(0, 200)}`);
  }
  assert.equal((await run(['topics', 'follow', 'metro'], { bin: 'bash', env })).code, 8);
  assert.equal((await run(['breaking', 'set', '--threshold', '1.5'], { bin: 'bash', env })).code, 6);
  assert.equal((await run(['unsubscribe', '--what', 'all'], { bin: 'bash', env })).code, 2);
  assert.equal((await run(['digest', '--date', '1999-01-01'], { bin: 'bash', env })).code, 4);
  assert.equal((await run(['me'], { bin: 'bash', env: { ...env, IO_TOKEN: 'ioa_000000000000_revokedrevokedrevoked' } })).code, 3);
  assert.equal((await run(['briefs'], { bin: 'bash', env: { ...env, IO_API: 'http://127.0.0.1:9/x' } })).code, 7);
});

test('mcp: stdio bridge to the Worker, stores the token from signup_verify', async (t) => {
  const dirs = [process.env.IO_MCP_DIR && path.resolve(process.env.IO_MCP_DIR), path.join(HERE, '..', '..', 'mcp'), path.join(HERE, '..', '..', 'io-mcp-worker')].filter(Boolean);
  const dir = dirs.find((d) => fs.existsSync(path.join(d, 'src', 'index.js')));
  if (!dir) { t.skip('io-mcp Worker source not found (set IO_MCP_DIR)'); return; }
  // #14: the source without its dependencies is a skip with a hint, not a failure.
  if (!fs.existsSync(path.join(dir, 'node_modules', 'agents'))) { t.skip(`run npm ci in ${dir} to run the bridge test`); return; }
  const { default: worker } = await import(path.join(dir, 'src', 'index.js'));
  const env = { IO_API: stub.api, SITE: stub.url };
  const srv = http.createServer(async (req, res) => {
    let body = '';
    for await (const c of req) body += c;
    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) headers.set(k, Array.isArray(v) ? v.join(',') : v);
    const r = await worker.fetch(new Request(`http://localhost${req.url}`, { method: req.method, headers, body: req.method === 'POST' ? body : undefined }), env, {});
    res.writeHead(r.status, Object.fromEntries(r.headers));
    res.end(Buffer.from(await r.arrayBuffer()));
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const url = `http://localhost:${srv.address().port}/mcp`;
  const h3 = fs.mkdtempSync(path.join(os.tmpdir(), 'io-mcp-'));
  const child = spawn(process.execPath, [BIN, 'mcp', '--url', url], { env: { PATH: process.env.PATH, HOME: h3, XDG_CONFIG_HOME: path.join(h3, '.config'), IO_API: stub.api } });
  const lines = []; let buf = '';
  child.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { lines.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1); } });
  const waitFor = async (id) => { for (let i = 0; i < 200; i++) { const m = lines.find((l) => l.id === id); if (m) return m; await new Promise((r) => setTimeout(r, 25)); } throw new Error(`no reply ${id}`); };
  const send = (m) => child.stdin.write(JSON.stringify(m) + '\n');
  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'desktop', version: '1' } } });
  const init = await waitFor(1);
  assert.equal(init.result.serverInfo.name, 'indianopinion');
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  send({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
  assert.equal((await waitFor(2)).result.tools.length, 15);
  send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'get_account', arguments: {} } });
  assert.equal((await waitFor(3)).result.isError, true, 'no token yet');
  send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'signup_verify', arguments: { email: EMAIL, code: GOOD_CODE } } });
  assert.equal((await waitFor(4)).result.structuredContent.token, GOOD_TOKEN);
  send({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'get_account', arguments: {} } });
  const acc = await waitFor(5);
  assert.ok(!acc.result.isError, JSON.stringify(acc));
  const f = path.join(h3, '.config', 'indianopinion', 'token');
  assert.equal(fs.statSync(f).mode & 0o777, 0o600);
  child.stdin.end();
  await new Promise((r) => child.on('exit', r));
  srv.close();
});
