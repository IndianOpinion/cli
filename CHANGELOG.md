# Changelog

All notable changes to the `indianopinion` npm package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.2.1] - 2026-10-19

### Added

- `account close --yes`: closes the account through `POST /agent/close`. Every token is revoked,
  every email stops and sign-in is disabled. It is deactivation, not deletion; the answer carries the
  retention statement (IndianOpinion/mcp#3).
- `briefs --until`, and `breaking recent --cursor` for windows of more than 500 events.
- `io.sh`: `briefs --q`, `--category`, `--until` and `--cursor`; `brief <url>` and `--include`;
  `doctor`, `token new`, `browser-link`, `account close`; `prefs set --digest` and `--nudges`;
  `topics follow --id`; `digest --limit`; `breaking recent --limit`, `--would-send` and `--cursor`;
  `--token` and `--api`. With jq it prints the same JSON as the CLI, and a cursor from either works
  in the other (#5, #11).
- SECURITY.md and CONTRIBUTING.md (#16).

### Fixed

- Unknown flags and extra words are usage errors (exit 2) in the CLI and `io.sh`, never ignored (#2).
- Usage errors exit 2 on every path, also through an installed bin; regression tests cover it (#3).
- `doctor` fails the version check only when this build is older than the published one (#4).
- `--since` and `--until` must be ISO 8601; anything else is exit 6 (#6).
- `brief --include` rejects unknown field names with exit 6 (#7).
- `io.sh` URL-encodes query values, so a `+05:30` offset or `&` survives (#12).
- The `io.sh` install line creates `~/bin` first (#13).
- The MCP bridge test skips with a hint when `../mcp` has no `node_modules` (#14).
- Docs, help and the login notice say that verifying a new address switches on the daily digest and
  Breaking News, and that `unsubscribe --what all --yes` stops both (#15).
- Following `--cursor` never skips a brief, even if the API returns more than the page asked for.

## [0.2.0] - 2026-10-18

First public release, from https://github.com/IndianOpinion/cli under the MIT
licence, and the first version meant for the npm registry. Version 0.1.0 was
distributed only as a tarball from https://indianopinion.org/agents/cli/.

### Added

- `briefs` uses the paging of `GET /wp-json/io/v1/briefs`: `--q` and
  `--category` are sent to the API, and `--cursor` follows the API's
  `next_cursor`. Against an API that does not page yet, the CLI filters and
  pages locally as before.
- Public commands: `briefs`, `brief` (by id or article URL).
- Account commands: `login start` and `login verify` (email code), `me`,
  `prefs`, `topics`, `digest`, `breaking`, `unsubscribe`, `token`.
- `mcp`: a stdio bridge to https://indianopinion.org/mcp for clients that only
  speak stdio; it stores the token returned by `signup_verify`.
- `skill install`: writes the Agent Skills file.
- `doctor`, `--help --json`, stable exit codes, JSON output when stdout is not
  a terminal.
- `io.sh`: the same commands for bash and curl, without `mcp` and `skill`.

[0.2.1]: https://github.com/IndianOpinion/cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/IndianOpinion/cli/releases/tag/v0.2.0
