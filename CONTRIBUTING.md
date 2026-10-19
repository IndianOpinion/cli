# Contributing

Thank you for helping. Please read this before opening a pull request.

## How this repository relates to the site

The CLI is developed in a private repository and mirrored here; npm releases are published from this
repository, and the copy served at https://indianopinion.org/agents/cli/ is rebuilt from a release.

- Pull requests here are reviewed by the maintainers. An accepted change is applied to the private
  repository, tested there and copied back, so your commit may land as part of a mirror update rather
  than as a merge of your branch.

## Making a change

1. Open an issue first for anything larger than a small fix, so we can agree on the approach.
2. Node 20 or newer. The CLI is one file with no dependencies; keep it that way.
3. Keep `io.sh` in step with the CLI: the same commands, flags, exit codes and (with jq) the same JSON.
   A flag either one does not take must be a usage error (exit 2), never ignored.
4. Run `npm test`. Add or update tests for any behaviour you change; they run against the local REST
   stub in `test/stub-rest.mjs` and must not use the network. The MCP bridge test needs a checkout of
   https://github.com/IndianOpinion/mcp at `../mcp` (or `IO_MCP_DIR`) with `npm ci` run in it.
5. If you add a command or flag, update `SPEC` and `COMMANDS` in `bin/indianopinion.mjs`, `io.sh`, the
   README and, when the skill text changes, `skill/SKILL.md` (`indianopinion skill install --print`).
6. A release bumps `version` in `package.json`, `VERSION` in `bin/indianopinion.mjs` and
   `IO_SH_VERSION` in `io.sh` together and adds a `CHANGELOG.md` entry.
7. Never commit a token, a real email address or an npm credential.

By contributing you agree that your contribution is licensed under the MIT licence of this repository.

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
