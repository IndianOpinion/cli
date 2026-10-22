# indianopinion: the Indian Opinion CLI

Indian news briefs, the daily digest, topic alerts and Breaking News from the command line, for people
and AI agents. One file, no dependencies, Node 20 or newer. Guide: https://indianopinion.org/agents/

MIT licensed. The MCP server this CLI bridges to is at https://github.com/IndianOpinion/mcp.

## Install

The package is not on the npm registry yet (the first publish is pending), so install it from this
repository or from the site:

```sh
npm i -g github:IndianOpinion/cli                         # this repository, the newest release
npm i -g https://indianopinion.org/agents/cli/latest.tgz   # the copy the site serves
npx --yes github:IndianOpinion/cli briefs --q "monsoon"   # run once without installing
```

Check a site download against `https://indianopinion.org/agents/cli/SHA256SUMS` or `latest.json`
(`{version, url, sha256}`). After the first npm publish, `npm i -g indianopinion` and
`npx --yes indianopinion` work too, and registry releases carry npm provenance that links each version
to the GitHub Actions run in this repository that built it.

Without Node, `io.sh` covers the same commands and flags except `mcp` and `skill` (bash and curl):

```sh
mkdir -p ~/bin && curl -fsSL https://indianopinion.org/agents/cli/io.sh -o ~/bin/io && chmod +x ~/bin/io
~/bin/io briefs --q monsoon --limit 3      # or add ~/bin to PATH and run io
```

With jq installed, `io.sh` prints the same JSON as the CLI; without jq it prints the API's JSON
unchanged, and the few flags that need reshaping (`digest --limit`, `breaking recent --limit` or
`--would-send`, `brief --include`) say they need jq. A flag a command does not take is a usage error
(exit 2) in both.

## Use

```sh
indianopinion briefs --q "bengaluru metro" --limit 10     # no account needed
indianopinion brief https://indianopinion.org/<slug>/      # no account needed
indianopinion login start --email you@yourdomain.example   # emails a 6-digit code
indianopinion login verify --email you@yourdomain.example --code 123456
indianopinion digest                                       # needs the token from login verify
indianopinion topics follow "Supreme Court" --tier instant
indianopinion breaking recent --days 7
indianopinion breaking set --threshold 0.4 --composite mean --max-per-day 3
indianopinion prefs set --format text --hour 7
indianopinion unsubscribe --what all --yes                 # stop every email
indianopinion account close --yes                          # close the account (see below)
indianopinion token list
indianopinion mcp                  # stdio MCP bridge to https://indianopinion.org/mcp
indianopinion skill install        # writes ~/.claude/skills/indianopinion/SKILL.md
indianopinion doctor
indianopinion --help --json        # every command and flag, machine-readable
```

Verifying a new address switches on the daily digest and Breaking News: the digest in plain text at
7 am India time by default, Breaking News at most 5 a day under the default rule. `unsubscribe --what all --yes`
stops both, topic alerts and reminders; `--what digest` or `--what breaking` stops one. An address that
already had an account keeps its own settings.

`account close --yes` closes the account: every token is revoked, every email stops and the address can
no longer sign in. It is deactivation, not deletion: the account record is kept, deactivated, under the
retention terms of https://indianopinion.org/privacy-policy/. To ask for erasure, a copy of your data or
reopening, write to hello@indianopinion.org.

Every command rejects a flag or extra word it does not take (exit 2), `--since` and `--until` must be
ISO 8601 (exit 6), and `brief --include` takes only `brief`, `analysis`, `coverage` and `sources`
(exit 6).

Output is JSON when stdout is not a terminal, or with `--json`; text on a terminal or with `--text`.
Errors go to stderr (a JSON object in JSON mode).

| Exit | Meaning |
|---|---|
| 0 | ok |
| 1 | unexpected, or a `doctor` check failed (a missing token is reported but is not a failure: exit 0, `signed_in: false`) |
| 2 | usage (including a missing `--yes`) |
| 3 | auth: no token, or it was refused |
| 4 | not found |
| 5 | rate limited (`retry_after` in the error) |
| 6 | validation |
| 7 | network or server |
| 8 | needs a choice (an ambiguous topic; options are listed) |

List commands take `--limit` up to 100, the REST API's page size. The MCP tools (`indianopinion mcp`
and the remote server) return at most 25 items per call; page on with their cursor.

Token order: `--token` (visible in `ps`, avoid), `IO_TOKEN`, then
`${XDG_CONFIG_HOME:-~/.config}/indianopinion/token` (written by `login verify` with mode 0600, directory
0700). `IO_API` changes the REST base (default `https://indianopinion.org/wp-json/io/v1`), `IO_MCP_URL`
the MCP endpoint for `mcp`, `IO_EMAIL` the default for `login`.

### MCP bridge

For clients that only speak stdio (Claude Desktop's config file, older Codex builds):

```json
{ "mcpServers": { "indianopinion": { "command": "indianopinion", "args": ["mcp"] } } }
```

It forwards each JSON-RPC message to `https://indianopinion.org/mcp` with the stored token, and when
`signup_verify` succeeds it stores the new token and uses it from the next call.

## Tests

```sh
npm test
```

They run the CLI and `io.sh` against a local stub of the REST API (`test/stub-rest.mjs`). No network.
The MCP bridge test also runs the io-mcp Worker when its source is found: set `IO_MCP_DIR`, or clone
https://github.com/IndianOpinion/mcp next to this checkout as `../mcp` and run `npm ci` there.
Without the source, or without its `node_modules`, that one test is skipped with a hint.

## Releasing

Releases go to npm from GitHub Actions through npm Trusted Publishing (OIDC). No npm token exists in
this repository or its secrets.

One-time setup (an npm owner of the package, on npmjs.com):

0. If `ci/workflows/` still exists, activate the workflows first as `ci/README.md` describes, so that
   `.github/workflows/publish.yml` is on `main`.

1. Publish the first version by hand, because npm attaches trusted publisher settings to an existing
   package. From a clean checkout of the newest release tag (`v0.2.2`), on your own machine with 2FA on:
   `npm login`, `npm test`, `npm pack --dry-run` (expect `bin/indianopinion.mjs`, `skill/SKILL.md`,
   `README.md`, `LICENSE`, `CHANGELOG.md`, `package.json`), then `npm publish --access public`.
   `publishConfig.provenance` only applies in CI; a local publish ignores it with a warning, or pass
   `--provenance=false`.
2. On https://www.npmjs.com/package/indianopinion/access, under Trusted Publisher, choose GitHub
   Actions and enter: Organization or user `IndianOpinion`, Repository `cli`, Workflow filename
   `publish.yml`, Environment name `npm`. Save.
3. On the same page, set Publishing access to "Require two-factor authentication and disallow
   tokens", so only the trusted workflow (and a human with 2FA) can publish.
4. On GitHub, Settings, Environments, create the environment `npm`; optionally add required reviewers
   so each publish waits for an approval.

Each release after that:

1. Bump `version` in `package.json`, `VERSION` in `bin/indianopinion.mjs` and `IO_SH_VERSION` in
   `io.sh` (the test workflow fails if they differ), and add a `CHANGELOG.md` entry.
2. Merge to `main`, then create a GitHub release with the tag `v<version>`.
3. The `publish` workflow checks that the tag matches the version, runs the tests and publishes with
   provenance.

The copy served at `https://indianopinion.org/agents/cli/` is rebuilt from a release by the
maintainers when the MCP Worker is deployed.

## Security and contributing

Report a vulnerability privately to hello@indianopinion.org (see [SECURITY.md](SECURITY.md)), never in a
public issue. How to propose a change: [CONTRIBUTING.md](CONTRIBUTING.md).
