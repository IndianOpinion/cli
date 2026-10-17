# Changelog

All notable changes to the `indianopinion` npm package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

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

[0.2.0]: https://github.com/IndianOpinion/cli/releases/tag/v0.2.0
