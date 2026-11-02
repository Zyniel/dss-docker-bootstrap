# Development

Both scripts need only Docker and bash (Git Bash on Windows).

## Lint

```shell
scripts/lint.sh
```

- [ShellCheck](https://www.shellcheck.net/) on every `*.sh`, and
  [Hadolint](https://github.com/hadolint/hadolint) on `image/Dockerfile`.
- Both run from their official images, at pinned versions.
- GitHub Actions runs it on every push and pull request
  ([`lint.yml`](../.github/workflows/lint.yml)).

## Smoke test

```shell
scripts/smoke-test.sh                                         # base images used in instances/
scripts/smoke-test.sh dataiku/dss:13.4.4 dataiku/dss:15.2.0   # given base images
scripts/smoke-test.sh --keep dataiku/dss:13.4.4               # keep the project to inspect it
```

For each base image, in a throwaway Compose project `dss-smoke-<version>`:

1. Builds the image, with the default JDBC drivers.
2. Checks that the container refuses to start with a license that is not
   JSON, a license path that is a folder, and data from another DSS version.
3. Starts DSS on a fresh volume and waits for `healthy`.
4. Checks the logs for errors, the JDBC drivers, and that DSS accepts the
   license in `license/` (or logs the free mode warning without one).
5. Restarts, and checks that nothing is installed again.

| Variable | Default | Use |
|---|---|---|
| `SMOKE_PORT` | `10100` | Host port (passed as `DSS_HOST_PORT`), so a running instance is not disturbed |
| `SMOKE_TIMEOUT` | `1200` | Seconds to wait for `healthy` |

- It takes a few minutes per base image.
- The project, its volumes and its image are removed at the end, even after a
  failure.
- The checks that run inside the container are in
  [`scripts/smoke-checks/`](../scripts/smoke-checks). The license check calls
  the DSS API the way `dsscli` does, through DSS internals that may change in a
  future DSS version.
- It does not run on GitHub Actions: the DSS images are several GB each.

## Before a change

- Run the lint and the smoke test on every base image in use: base images
  differ, down to the tools they include (13.4.4 has no `cmp`, for example).
- Read the full container logs, not only the expected lines.

## Releases

A release updates `CHANGELOG.md`, tags the commit and pushes both. GitHub
Actions then creates the GitHub release for the tag
([`release.yml`](../.github/workflows/release.yml)). From an up-to-date
`main`, with [git-cliff](https://git-cliff.org) installed:

**First release**, with an explicit version (there is no previous tag to bump
from):

```shell
git cliff --tag v1.0.0 -o CHANGELOG.md
git add CHANGELOG.md && git commit -m "chore(release): v1.0.0"
git tag v1.0.0 && git push origin main v1.0.0
```

**Next releases**, with the version derived from the commits since the last
tag (`feat:` bumps the minor version, anything else the patch version):

```shell
version=$(git cliff --bumped-version)
git cliff --bump -o CHANGELOG.md && git commit -am "chore(release): $version"
git tag "$version" && git push origin main "$version"
```

- The changelog and the release notes are generated from
  [`cliff.toml`](../cliff.toml). Commits are grouped by their
  [Conventional Commits](https://www.conventionalcommits.org) prefix:
  `feat:` (Features), `fix:` (Fixes), `docs:` (Documentation), anything else
  (Changes). Merge commits and `chore(release)` commits are left out.
- The GitHub release lists only the tag's own changes.
- Preview before releasing:

  ```shell
  git cliff --unreleased        # changes since the last tag
  git cliff --bumped-version    # the next version
  ```

## Shell script conventions

- A header saying what the script does and where it runs: on the host, at
  image build, at container start, or inside the test container.
- `set -euo pipefail`, except where DSS's own scripts are loaded.
- Messages: `[+]` progress, `[!]` warning, `[-]` error (to stderr), as in the
  DSS installer. The tools use `[smoke]` and `[lint]`.
- Functions documented as `name ARGS: what it does`, with named locals.
- No hidden failures: capture command output in a variable before comparing
  it, and stop explicitly in functions called from an `if`, where `set -e` does
  not apply.

## Windows

- `.gitattributes` keeps LF line endings: the scripts run in Linux containers,
  where CRLF breaks them.
- Git Bash rewrites arguments that look like Unix paths. The scripts set
  `MSYS_NO_PATHCONV=1`, and use `pwd -W` for paths passed to Docker. Do the same
  for manual `docker` commands:

  ```shell
  MSYS_NO_PATHCONV=1 docker exec dss-15-2-0-dss-1 ls /home/dataiku/dss/lib/jdbc
  ```
