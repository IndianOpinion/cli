# GitHub Actions workflows (not yet active)

`workflows/test.yml` (tests on push and pull request) and `workflows/publish.yml` (npm publish
through Trusted Publishing on a GitHub release) are ready but sit here because the initial push was
made with a credential that may not create workflow files. A maintainer activates them with:

```sh
git mv ci/workflows .github/workflows && git rm ci/README.md
git commit -m "Activate the test and publish workflows" && git push
```

Trusted Publishing on npm expects the workflow at `.github/workflows/publish.yml`.
