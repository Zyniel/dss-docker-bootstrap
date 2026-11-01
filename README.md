# Dataiku DSS Docker bootstrap

Start a versioned Dataiku DSS node with Docker Compose. A small custom image
extends the official versioned DSS image so that optional JDBC drivers (Oracle,
Trino) and an optional license file are installed into the DSS data directory
before DSS starts, on both a fresh and an existing data directory. The DSS data
directory is persistent in a Docker-managed named volume.

## Requirements

- Docker Engine with the Compose plugin (or Docker Desktop)
- Optionally, a Dataiku DSS license file at `license/license.json`. Without one,
  DSS runs in its default free mode.

## Configure

Copy `.env.example` to `.env`, then set the desired DSS image tag and digest,
host port and JDBC driver versions:

```dotenv
DSS_VERSION=13.4.4
DSS_PORT=10000
DSS_IMAGE_DIGEST=sha256:8bc5cd7512506a453e9ba9866786ff22937b3194dc70039539e5d04890b6a002
ORACLE_JDBC_VERSION=21.24.0.0
TRINO_JDBC_VERSION=484
DSS_ALLOW_UPGRADE=
```

`DSS_VERSION` must be a version tag published for
[`dataiku/dss`](https://hub.docker.com/r/dataiku/dss/tags) on Docker Hub, such
as `13.4.4`. Not every DSS release has one. The JDBC driver versions are
described in [JDBC drivers](#jdbc-drivers), and `DSS_ALLOW_UPGRADE` in
[Upgrade DSS](#upgrade-dss).

`DSS_IMAGE_DIGEST` pins the exact base image published under that tag, so the
build does not change if the tag is pushed again. When a digest is given,
Docker uses it and ignores the tag, so it must be the digest of
`dataiku/dss:<DSS_VERSION>`: the build checks that the base image contains that
DSS version and fails otherwise. Change both together, and get the digest of a
tag with:

```powershell
docker buildx imagetools inspect dataiku/dss:15.2.0
```

| Tag | Digest (as published on 2026-11-01) |
|---|---|
| `13.4.4` | `sha256:8bc5cd7512506a453e9ba9866786ff22937b3194dc70039539e5d04890b6a002` |
| `15.2.0` | `sha256:04b18e413e617d6485c317737228a6b16dcd899f815ee2a626c2b2b0e428582f` |

Leave `DSS_IMAGE_DIGEST` unset to use the 13.4.4 digest, or set it to empty
(`DSS_IMAGE_DIGEST=`) to build from the tag alone.

The image listens on container port `10000`; `DSS_PORT` selects the host port,
bound to `127.0.0.1` so DSS is not exposed to the network by default. The first
startup initializes the `dss-data` Docker volume. A named volume avoids
host-directory ownership problems with the unprivileged `dataiku` container
user.

## Start and stop

```powershell
Copy-Item .env.example .env
docker compose up --build -d
```

Open `http://localhost:10000` (or replace `10000` with the configured `DSS_PORT`).
View startup logs with `docker compose logs -f dss`, and stop the node with
`docker compose down`. The persistent data remains in the `dss-data` Docker
volume: `docker compose down` preserves it, `docker compose down --volumes`
deletes it. Rebuild the custom image after changing the DSS version or startup
wrapper with `docker compose up --build -d`. The image is named after the
Compose project and the DSS version, for example `dss-docker-bootstrap-dss:13.4.4`
(the project name defaults to the folder name, or is set with `-p`), so
projects built with different settings never replace each other's image.
A newer DSS version is not applied
to an existing data directory until you allow it; see
[Upgrade DSS](#upgrade-dss).

The image has a healthcheck: `docker compose ps` shows the container as
`healthy` once the DSS backend answers on `/dip/api/ping`. It stays `starting`
while DSS is being installed, upgraded or started, which can take several
minutes, and turns `unhealthy` if the backend stops answering.

A fresh data directory has the DSS default `admin` / `admin` login. Change the
password at first login. The container listens only on `127.0.0.1` by default
and has `no-new-privileges` enabled; do not expose the port before the
password is changed. Docker retries failed container starts up to three times.

## Upgrade DSS

Starting a newer `DSS_VERSION` on an existing data directory upgrades it in
place, and that cannot be undone: DSS cannot downgrade a data directory. So the
container never upgrades on its own:

- When the data directory is from an older DSS, it refuses to start and logs
  both versions (once per Docker retry, so four times), unless
  `DSS_ALLOW_UPGRADE` is set to the new version. Changing
  `DSS_VERSION` alone, or a `DSS_VERSION` left in the shell environment (Compose
  prefers it to `.env`), therefore never upgrades.
- When the upgrade is allowed, it first saves the whole data directory to
  `backups/dss-data-<old version>-<UTC date and time>.tar.gz`, then upgrades.
  DSS is not running yet, so the backup is consistent. If the backup cannot be
  written, the data directory is left as is and the container exits.
- When the data directory is from a newer DSS, it refuses to start. DSS's own
  installer does not check for this.

To upgrade, for example from 13.4.4 to 15.2.0, set in `.env`:

```dotenv
DSS_VERSION=15.2.0
DSS_IMAGE_DIGEST=sha256:04b18e413e617d6485c317737228a6b16dcd899f815ee2a626c2b2b0e428582f
DSS_ALLOW_UPGRADE=15.2.0
```

then rebuild and start with `docker compose up --build -d`. Since
`DSS_ALLOW_UPGRADE` names one version, leaving it in `.env` does not allow the
next upgrade. The backup takes as much disk space as the data directory,
compressed, and time to write; remove old backups from `backups/` yourself.

To go back to the version before the upgrade, restore its backup into a new,
empty volume. This deletes the upgraded data directory:

1. Set `DSS_VERSION` and `DSS_IMAGE_DIGEST` back to the old version in `.env`.
2. Delete the upgraded volume and restore the backup into a new one, replacing
   the file name:

   ```powershell
   docker compose down --volumes
   docker compose run --rm --no-deps dss tar -xzf /home/dataiku/backups/dss-data-13.4.4-20261101T120000Z.tar.gz -C /home/dataiku/dss
   ```

3. Start DSS with `docker compose up --build -d`.

On Linux hosts, `backups/` must be writable by uid 1000, the `dataiku` user in
the container. The folder is in the repository so that Docker does not create
it owned by root. Docker Desktop does not need this.

## JDBC drivers

The image can include the Oracle and Trino JDBC drivers. They are downloaded
from Maven Central when the image is built, and each jar is checked against the
SHA-256 checksum Maven Central publishes for it.

| `.env` variable | Default | Jars | Installed in the data directory at |
|---|---|---|---|
| `ORACLE_JDBC_VERSION` | `21.24.0.0`, the latest Oracle 21c driver | `ojdbc11-<version>.jar`, `orai18n-<version>.jar` | `lib/jdbc/` |
| `TRINO_JDBC_VERSION` | `484`, the latest Trino driver | `trino-jdbc-<version>.jar` | `lib/jdbc/trino/` |

Both drivers are optional: leave a variable empty (for example
`TRINO_JDBC_VERSION=`) to leave that driver out of the image. The versions are
build arguments, so rebuild after changing them:

```powershell
docker compose up --build -d
```

The jars cannot be placed in the data directory when the image is built: the
DSS installer needs an empty data directory, and the `dss-data` volume is
mounted over it at runtime anyway. So the image keeps them in
`/home/dataiku/jdbc-drivers`, and [`start-dss.sh`](start-dss.sh) copies them into
`lib/jdbc` on every start, before DSS starts. It lists what it installed in
`lib/jdbc/.dss-bootstrap-drivers`, and at the next start removes jars from a
previous version or from a driver that was turned off, so two versions of a
driver never sit side by side. Jars you add to `lib/jdbc` yourself are left
alone; do not add other versions of these two drivers there.

Using the drivers in DSS:

- **Oracle**: `lib/jdbc` is on the DSS classpath, so Oracle connections use the
  driver with no further setting. `ojdbc11` supports Java 11 and later; DSS runs
  on Java 17. `orai18n` adds the character sets `ojdbc11` does not include on
  its own, which some databases need.
- **Trino**: some DSS versions, such as 13.4 and 15.2, bundle their own Trino
  driver, and connections keep using it by default. To use the driver installed
  here, set each Trino connection's driver mode to "User provided" and its
  driver directory to `lib/jdbc/trino`, as described in
  [Dataiku's Trino documentation](https://doc.dataiku.com/dss/latest/connecting/sql/trino.html).
  Through the DSS API, these are the connection parameters
  `"driverMode": "CUSTOM"` and `"jarsDirectory": "lib/jdbc/trino"`.
  Trino recommends a driver version equal to or newer than the Trino cluster
  version.

## How the license is injected

Three constraints shape the startup flow:

- The DSS installer only initializes an empty data directory, so the license
  cannot be mounted inside the data directory before the first start.
- The base image's `/home/dataiku/run.sh` initializes or upgrades the data
  directory and then immediately `exec`s `dss run`, with no hook in between.
- `dsscli set-license` goes through the DSS API, so it needs a running backend,
  and DSS must then be restarted. It also sends the file without a charset, so
  DSS misreads non-ASCII characters (such as a `ç` in the licensee name) and
  rejects a valid license with "Your license is not validly signed".

DSS reads its license from `DATA_DIR/config/license.json` when it starts; the
installer's own `-l LICENSE_FILE` option only copies the file there. The image
uses that:

1. At build time, `/home/dataiku/dss-init.sh` is derived from the base image's
   `run.sh` without its final `exec "$DSS_DATADIR"/bin/dss run` line. The build
   fails if that line is not found, so a changed upstream script cannot be
   silently ignored after a `DSS_VERSION` bump.
2. At container start, [`start-dss.sh`](start-dss.sh) checks that the license
   file, when present, is readable JSON, checks the data directory version
   (see [Upgrade DSS](#upgrade-dss)), runs `dss-init.sh` (install on an empty
   volume, upgrade when allowed, nothing otherwise), installs the
   [JDBC drivers](#jdbc-drivers), copies the license to `config/license.json`
   when it differs, then `exec`s `dss run`.

DSS starts once, already licensed: there is no API polling and no restart.

The `license/` folder is bind-mounted read-only at `/home/dataiku/license`,
outside the data directory. A folder is mounted rather than the file itself so
that the license stays optional: Docker cannot mount a single file that may not
exist. Set `DSS_LICENSE_FILE` on the service to read the license from another
path inside the container.

When `license/license.json` is present, it is the source of truth: it overwrites
`config/license.json` on every start, so a license entered in the DSS UI is
replaced at the next start. After adding or updating it, restart the container:

```powershell
docker compose restart dss
```

When it is absent, startup continues with a warning in the logs:

- if the data directory has no license yet, DSS runs in its default free mode;
- if a license was installed earlier (from this folder or through the DSS UI),
  it is kept. Delete `config/license.json` from the data directory to drop it.

If the license file is unreadable or not valid JSON, the container exits with an
error before DSS starts. Whether the license itself is accepted (signature,
expiry) is decided by DSS at startup; check `docker compose logs dss` and the
DSS administration page.

On Linux hosts the bind mount keeps the host file's ownership and permissions.
The container runs as `dataiku` (uid 1000), so `license/license.json` must be
readable by that uid, for example owned by uid 1000 with mode `600`. Docker
Desktop does not need this.

## Development

Two scripts check changes; both need only Docker, and run from Git Bash on
Windows:

- `scripts/lint.sh` runs [ShellCheck](https://www.shellcheck.net/) on the shell
  scripts and [Hadolint](https://github.com/hadolint/hadolint) on the
  Dockerfile, from their official images.
- `scripts/smoke-test.sh` builds the image and tests it end to end in a
  throwaway Compose project: refusals on an unusable license and on a data
  directory from another DSS version, a fresh install up to `healthy`, the
  startup logs, the JDBC drivers, the license as accepted by DSS, and a restart
  that installs nothing again. The checks that run inside the DSS container
  are in `scripts/smoke-checks/`. It takes several minutes per version. Without
  arguments it tests the version `docker-compose.yml` resolves; otherwise pass
  versions, with or without a digest:

  ```bash
  scripts/smoke-test.sh 13.4.4 15.2.0@sha256:04b18e413e617d6485c317737228a6b16dcd899f815ee2a626c2b2b0e428582f
  ```

  It uses host port 10100 (`SMOKE_PORT`) and its own image,
  `dss-smoke-<version>-dss:<version>`, deleted at the end, so it can run next
  to a running node without touching it. `--keep` leaves the test project and
  its image in place for inspection.

Run both before changing `DSS_VERSION` or the scripts: the base images differ
between DSS versions, down to the tools they include.

`.gitattributes` keeps LF line endings in the working tree on Windows: the
scripts run in Linux containers, where CRLF line endings break them.

## License and image usage

Keep the license file at `license/license.json`. It is ignored by Git and
excluded from the build context, as are `.env` and other `.env.*` files.

The public `dataiku/dss` Docker Hub image is described as intended for evaluation
and not production use. Dataiku also warns that running DSS in a container is
unsupported and generally incompatible with using containers as a processing
engine. Consult your Dataiku account team before using this deployment model:
[Dataiku container installation guidance](https://doc.dataiku.com/dss/latest/installation/other/container.html).
