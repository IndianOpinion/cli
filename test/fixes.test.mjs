// Tests for the 0.2.1 fixes (19 October 2026): IndianOpinion/cli #2 to #7 and
// #11 to #16, IndianOpinion/mcp #3 (account close).
// Node CLI and io.sh against the REST stub; no network.
//   node --test test/*.test.mjs

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startStub, GOOD_TOKEN } from './stub-rest.mjs';
import { compareVersions, isoTime, checkArgs, SPEC } from '../bin/indianopinion.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const BIN = path.join(ROOT, 'bin', 'indianopinion.mjs');
const IOSH = path.join(ROOT, 'io.sh');
const HAVE_CURL = spawnSync('bash', ['-c', 'command -v curl']).status === 0;
const HAVE_JQ = spawnSync('bash', ['-c', 'command -v jq']).status === 0;
let stub; let native; let home;

function run(args, { env = {}, bin = 'node', exe } = {}) {
  const [cmd, argv] = exe ? [exe, args] : bin === 'node' ? [process.execPath, [BIN, ...args]] : ['bash', [IOSH, ...args]];
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { env: { PATH: process.env.PATH, HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'), IO_API: stub.api, IO_TOKEN: GOOD_TOKEN, ...env } });
    let out = ''; let errs = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { errs += d; });
    child.stdin.end();
    child.on('close', (code) => {
      let json = null; let errJson = null;
      try { json = JSON.parse(out); } catch { /* text */ }
      try { errJson = JSON.parse(errs.trim().split('\n').pop()); } catch { /* text */ }
      resolve({ code, out, err: errs, json, errJson });
    });
  });
}

before(async () => {
  stub = await startStub();
  native = await startStub({ briefsNative: true });
  home = fs.mkdtempSync(path.join(os.tmpdir(), 'io-fix-'));
});
after(async () => { await stub.close(); await native.close(); });

test('#2: unknown flags and extra words are usage errors (exit 2), in the CLI and io.sh', async () => {
  for (const bin of ['node', 'bash']) {
    if (bin === 'bash' && !HAVE_CURL) continue;
    let r = await run(['briefs', '--bogus'], { bin });
    assert.equal(r.code, 2, `${bin} briefs --bogus: ${r.out}`);
    assert.equal(r.errJson.error, 'usage');
    assert.match(r.errJson.message, /--bogus/);
    r = await run(['briefs', '--query', 'x'], { bin });
    assert.equal(r.code, 2, `${bin} --query`);
    r = await run(['breaking', 'status', '--days', '3'], { bin });
    assert.equal(r.code, 2, `${bin} breaking status --days`);
    r = await run(['topics', 'unfollow', '1', '2'], { bin });
    assert.equal(r.code, 2, `${bin} two topic ids`);
    r = await run(['me', '--yes'], { bin });
    assert.equal(r.code, 2, `${bin} me --yes`);
  }
  let r = await run(['briefs', 'extra-arg']);
  assert.equal(r.code, 2);
  r = await run(['briefs', '--q']);
  assert.equal(r.code, 2, 'a value flag with no value');
  // Every command in the help list has a flag spec, and every flag the help shows is accepted.
  const help = (await run(['--help', '--json'])).json.commands;
  for (const c of help) {
    const [cmd, sub] = c.cmd.split(' ');
    const key = SPEC[`${cmd} ${sub}`] ? `${cmd} ${sub}` : cmd;
    assert.ok(SPEC[key], `spec for ${c.cmd}`);
    for (const f of c.flags) assert.ok(SPEC[key].flags.includes(f.split(' ')[0].replace(/^--/, '')), `${c.cmd} accepts ${f}`);
  }
  assert.throws(() => checkArgs('briefs', undefined, [], { nope: 'x' }), /Unknown flag --nope/);
});

test('#3: every usage error exits 2, also through an installed (symlinked) bin', async () => {
  const bindir = fs.mkdtempSync(path.join(os.tmpdir(), 'io-bin-'));
  const link = path.join(bindir, 'indianopinion');
  fs.symlinkSync(BIN, link);
  fs.chmodSync(BIN, 0o755);
  for (const args of [['briefs', '--limit', '999'], ['briefs', '--limit', 'abc'], ['briefs', '--limit', '0'], ['token', 'revoke', 'abc'], ['unsubscribe', '--what', 'all']]) {
    for (const opt of [{}, { exe: link }]) {
      const r = await run(args, opt);
      assert.equal(r.code, 2, `${opt.exe ? 'symlink' : 'node'} ${args.join(' ')} -> ${r.code} ${r.err}`);
      assert.equal(r.out, '', 'nothing on stdout');
    }
  }
  const r = await run(['briefs', '--limit', '999', '--text']);
  assert.equal(r.code, 2);
});

test('#4: doctor passes when this build is newer than the published one, fails when older', async () => {
  assert.equal(compareVersions('0.2.1', '0.1.0'), 1);
  assert.equal(compareVersions('0.2.1', '0.2.1'), 0);
  assert.equal(compareVersions('0.2.1', '0.10.0'), -1);
  for (const [latest, ok] of [['0.1.0', true], ['0.2.1', true], ['9.0.0', false]]) {
    stub.state.latest = latest;
    const r = await run(['doctor']);
    const v = r.json.checks.find((c) => c.name === 'version');
    assert.equal(v.ok, ok, `latest ${latest}: ${v.detail}`);
    assert.equal(r.code, ok ? 0 : 1, `doctor exit with latest ${latest}`);
  }
  stub.state.latest = null;
});

test('#6: --since and --until must be ISO 8601 (exit 6); valid offsets reach the API intact', async () => {
  assert.ok(isoTime('2026-10-19T00:00:00+05:30'));
  assert.ok(isoTime('2026-10-19'));
  assert.equal(isoTime('yesterday'), null);
  assert.equal(isoTime('2026-13-45'), null);
  let r = await run(['briefs', '--since', 'yesterday', '--limit', '3']);
  assert.equal(r.code, 6);
  assert.equal(r.errJson.field, 'since');
  r = await run(['briefs', '--until', '2026-02-30']);
  assert.equal(r.code, 6);
  const before2 = native.requests.length;
  r = await run(['briefs', '--since', '2026-10-19T00:00:00+05:30', '--limit', '2'], { env: { IO_API: native.api } });
  assert.equal(r.code, 0, r.err);
  assert.equal(r.json.count, 0, 'nothing after a future time');
  const q = native.requests.slice(before2).find((x) => x.path.endsWith('/briefs'));
  assert.equal(new URLSearchParams(q.search).get('since'), '2026-10-19T00:00:00+05:30');
});

test('#7: brief --include rejects unknown fields (exit 6)', async () => {
  let r = await run(['brief', '99812', '--include', 'nonsense']);
  assert.equal(r.code, 6);
  assert.equal(r.errJson.field, 'include');
  assert.deepEqual(r.errJson.allowed, ['brief', 'analysis', 'coverage', 'sources']);
  r = await run(['brief', '99812', '--include', 'summary']);
  assert.equal(r.code, 6);
  r = await run(['brief', '99812', '--include', 'brief,coverage']);
  assert.equal(r.code, 0, r.err);
  assert.ok(r.json.brief && r.json.stances && !r.json.sources);
});

test('following --cursor never skips a brief, even when the API overfills a page', async () => {
  const over = await startStub({ briefsNative: true, briefsOversize: true });
  try {
    for (const s of [native, over]) {
      const seen = []; let cursor;
      for (let i = 0; i < 5; i++) {
        const r = await run(['briefs', '--limit', '2', ...(cursor ? ['--cursor', cursor] : [])], { env: { IO_API: s.api } });
        assert.equal(r.code, 0, r.err);
        seen.push(...r.json.items.map((x) => x.post_id));
        cursor = r.json.next_cursor;
        if (!cursor) break;
      }
      assert.deepEqual(seen, [99812, 99790, 99770, 99750, 99730]);
    }
  } finally { await over.close(); }
});

test('#5, #11: io.sh briefs takes --q, --category, --until and --cursor and prints the CLI shape', { skip: !HAVE_CURL || !HAVE_JQ }, async () => {
  const env = { IO_API: native.api };
  for (const args of [['briefs', '--q', 'metro', '--limit', '3'], ['briefs', '--limit', '2'], ['briefs', '--category', 'Politics', '--until', '2026-10-03T00:00:00Z', '--limit', '2']]) {
    const a = await run(args, { env });
    const b = await run(args, { env, bin: 'bash' });
    assert.equal(a.code, 0, a.err);
    assert.equal(b.code, 0, b.err);
    assert.deepEqual(b.json, a.json, `io.sh ${args.join(' ')} equals the CLI`);
  }
  const q = await run(['briefs', '--q', 'metro', '--limit', '3'], { env, bin: 'bash' });
  assert.deepEqual(q.json.items.map((x) => x.post_id), [99812], '--q filters');
  // A cursor from either tool works in the other.
  const p1 = await run(['briefs', '--limit', '2'], { env, bin: 'bash' });
  const p2 = await run(['briefs', '--limit', '2', '--cursor', p1.json.next_cursor], { env });
  assert.deepEqual(p2.json.items.map((x) => x.post_id), [99770, 99750]);
  const p3 = await run(['briefs', '--limit', '2', '--cursor', p2.json.next_cursor], { env, bin: 'bash' });
  assert.deepEqual(p3.json.items.map((x) => x.post_id), [99730]);
});

test('#11: io.sh brief <url>, doctor, token new, browser-link, prefs --digest/--nudges, topics follow --id, digest --limit', { skip: !HAVE_CURL || !HAVE_JQ }, async () => {
  const sh = (args, env = {}) => run(args, { bin: 'bash', env });
  let r = await sh(['brief', `${stub.url}/story-99812/`]);
  assert.equal(r.code, 0, r.err);
  assert.equal(r.json.id, 99812);
  r = await sh(['brief', `${stub.url}/story-99812.md`, '--include', 'sources']);
  assert.equal(r.json.sources.length, 3);
  assert.equal(r.json.analysis, undefined);
  r = await sh(['brief', 'https://example.com/x/']);
  assert.equal(r.code, 6);
  r = await sh(['doctor']);
  assert.equal(r.code, 0, r.out + r.err);
  assert.ok(r.json.checks.find((c) => c.name === 'token valid').ok);
  r = await sh(['token', 'new', '--label', 'ci']);
  assert.ok(r.json.token.startsWith('ioa_'));
  r = await sh(['browser-link']);
  assert.match(r.json.browser_url, /browser/);
  r = await sh(['prefs', 'set', '--digest', 'off', '--nudges', 'on']);
  assert.equal(r.code, 0, r.err);
  const body = JSON.parse(stub.requests.filter((x) => x.path.endsWith('/agent/preferences') && x.method === 'PATCH').at(-1).body);
  assert.deepEqual(body, { digest: { on: false }, nudges: true });
  r = await sh(['topics', 'follow', '--id', '88']);
  assert.equal(r.code, 0, r.err);
  r = await sh(['digest', '--limit', '1']);
  assert.equal(r.json.stories.length, 1);
  r = await sh(['breaking', 'status']);
  assert.deepEqual(Object.keys(r.json), ['ok', 'breaking', 'sent_last_24h']);
  r = await sh(['breaking', 'recent', '--would-send']);
  assert.equal(r.json.events.length, 1);
});

test('#12: io.sh URL-encodes query values, so a +05:30 offset is not lost', { skip: !HAVE_CURL }, async () => {
  const before2 = native.requests.length;
  const r = await run(['briefs', '--since', '2026-10-19T00:00:00+05:30', '--q', 'a&b #c', '--limit', '2'], { env: { IO_API: native.api }, bin: 'bash' });
  assert.equal(r.code, 0, r.err);
  const q = new URLSearchParams(native.requests.slice(before2).find((x) => x.path.endsWith('/briefs')).search);
  assert.equal(q.get('since'), '2026-10-19T00:00:00+05:30');
  assert.equal(q.get('q'), 'a&b #c');
  const bad = await run(['briefs', '--since', 'yesterday'], { bin: 'bash' });
  assert.equal(bad.code, 6);
});

test('io.sh without jq prints the API JSON, and flags that need jq say so', { skip: !HAVE_CURL }, async () => {
  const env = { IO_SH_NO_JQ: '1', IO_API: native.api };
  let r = await run(['briefs', '--limit', '2'], { bin: 'bash', env });
  assert.equal(r.code, 0, r.err);
  assert.equal(r.json.items[0].id, 99812, 'the API shape');
  r = await run(['digest', '--limit', '1'], { bin: 'bash', env });
  assert.equal(r.code, 2);
  assert.match(r.errJson.message, /needs jq/);
});

test('mcp #3: account close needs --yes, then closes; the retention statement is shown', async () => {
  const s = await startStub();
  try {
    for (const bin of ['node', 'bash']) {
      if (bin === 'bash' && !HAVE_CURL) continue;
      s.state.closed = false;
      let r = await run(['account', 'close'], { bin, env: { IO_API: s.api } });
      assert.equal(r.code, 2, `${bin} without --yes`);
      assert.equal(s.state.closed, false);
      r = await run(['account', 'close', '--yes'], { bin, env: { IO_API: s.api } });
      assert.equal(r.code, 0, `${bin}: ${r.err}`);
      assert.equal(r.json.closed, true);
      assert.equal(r.json.deleted, false);
      assert.match(r.json.retention, /does not delete/);
      assert.deepEqual(JSON.parse(s.requests.filter((x) => x.path.endsWith('/agent/close')).at(-1).body), { confirm: true });
      r = await run(['me'], { bin, env: { IO_API: s.api } });
      assert.equal(r.code, 3, `${bin}: the token no longer works`);
    }
    s.state.closed = false;
    const t = await run(['account', 'close', '--yes', '--text'], { env: { IO_API: s.api } });
    assert.match(t.out, /does not delete it/);
  } finally { await s.close(); }
});

test('#15: README, SKILL.md, help and login text say verification switches on the digest AND Breaking News', async () => {
  const readme = fs.readFileSync(path.join(ROOT, 'README.md'), 'utf8');
  const skill = fs.readFileSync(path.join(ROOT, 'skill', 'SKILL.md'), 'utf8');
  for (const [name, t] of [['README', readme], ['SKILL.md', skill]]) {
    assert.match(t, /daily digest and Breaking News/, name);
    assert.match(t, /unsubscribe --what all --yes/, name);
  }
  const help = (await run(['--help', '--json'])).json.commands.find((c) => c.cmd === 'login verify');
  assert.match(help.does, /Breaking News/);
  assert.match(fs.readFileSync(IOSH, 'utf8'), /daily digest and Breaking News/);
});

test('#13: every install line creates ~/bin before writing to it', () => {
  for (const f of ['README.md', 'io.sh']) {
    const t = fs.readFileSync(path.join(ROOT, f), 'utf8');
    for (const line of t.split('\n').filter((l) => l.includes('io.sh -o ~/bin/io'))) assert.match(line, /mkdir -p ~\/bin &&/, `${f}: ${line}`);
  }
});

test('#14: the bridge test skips (not fails) when the Worker source has no node_modules', () => {
  const fake = fs.mkdtempSync(path.join(os.tmpdir(), 'io-fake-mcp-'));
  fs.mkdirSync(path.join(fake, 'src'));
  fs.writeFileSync(path.join(fake, 'src', 'index.js'), "import 'agents';\nexport default {};\n");
  const r = spawnSync(process.execPath, ['--test', '--test-reporter=tap', '--test-name-pattern=stdio bridge', path.join(HERE, 'cli.test.mjs')], { env: { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => k !== 'NODE_TEST_CONTEXT')), IO_MCP_DIR: fake }, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout.slice(-800));
  assert.match(r.stdout, /# skipped 1/);
  assert.match(r.stdout, /run npm ci in/);
});

test('#16: SECURITY.md and CONTRIBUTING.md exist and name the private route and the test command', () => {
  const sec = fs.readFileSync(path.join(ROOT, 'SECURITY.md'), 'utf8');
  const con = fs.readFileSync(path.join(ROOT, 'CONTRIBUTING.md'), 'utf8');
  assert.match(sec, /hello@indianopinion\.org/);
  assert.match(sec, /Supported versions/);
  assert.match(con, /npm test/);
  assert.match(con, /io\.sh/);
});

test('versions agree: package.json, the CLI, io.sh and the CHANGELOG', async () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  assert.equal((await run(['--version'])).json.version, pkg.version);
  assert.match(fs.readFileSync(IOSH, 'utf8'), new RegExp(`^IO_SH_VERSION=${pkg.version.replaceAll('.', '\\.')}$`, 'm'));
  const cl = path.join(ROOT, 'CHANGELOG.md');
  if (fs.existsSync(cl)) assert.match(fs.readFileSync(cl, 'utf8'), new RegExp(`## \\[${pkg.version.replaceAll('.', '\\.')}\\]`));
});
