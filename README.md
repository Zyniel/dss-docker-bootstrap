# Dataiku DSS Docker bootstrap

Local Dataiku DSS servers for tests, with Docker Compose. A small custom image
extends the official versioned DSS image so that optional JDBC drivers (Oracle,
Trino) and an optional license file are installed into the DSS data directory
before DSS starts. Each server, or instance, keeps its data in its own Docker
volume.

## Requirements

- Docker Engine with the Compose plugin (or Docker Desktop)
- Optionally, a Dataiku DSS license file at `license/license.json`, used by
  every instance. Without one, DSS runs in its default free mode.

## Instances

Each instance is a folder in `instances/` with one `compose.yaml`, which extends
the settings shared by all instances in [`compose.base.yaml`](compose.base.yaml):

```yaml
services:
  dss:
    extends:
      file: ../../compose.base.yaml
      service: dss
    build:
      args:
        DSS_BASE_IMAGE: dataiku/dss:15.2.0@sha256:04b18e413e617d6485c317737228a6b16dcd899f815ee2a626c2b2b0e428582f
        ORACLE_JDBC_VERSION: 21.24.0.0
        TRINO_JDBC_VERSION: ""
    ports:
      - "127.0.0.1:10000:10000"

volumes:
  dss-data:
```

- `DSS_BASE_IMAGE` is the official image to build on: a
  [`dataiku/dss`](https://hub.docker.com/r/dataiku/dss/tags) version tag, such
  as `dataiku/dss:15.2.0`. Not every DSS release has one. Adding `@` and the
  tag's digest pins the exact image published under that tag; get it with
  `docker buildx imagetools inspect dataiku/dss:15.2.0`. With a digest, Docker
  ignores the tag, so the build checks that the tag is the DSS version in the
  image and fails otherwise. Without this setting, the image is built on
  `dataiku/dss:13.4.4`.
- `ORACLE_JDBC_VERSION` and `TRINO_JDBC_VERSION` select the
  [JDBC drivers](#jdbc-drivers); leave them out to get the defaults.
- `ports` selects the host port, bound to `127.0.0.1` so DSS is not exposed to
  the network. Give each instance its own port.
- The `volumes` block at the end is required: `extends` does not carry it over
  from the base file.

The folder name is the instance's Compose project name, so it names the
container (`<name>-dss-1`), the image (`<name>-dss`) and the data volume
(`<name>_dss-data`). Use lowercase letters, digits and dashes. To create an
instance, copy a folder under a new name, then change the base image, drivers
and port in its `compose.yaml`.

## Start and stop

From the instance's folder:

```powershell
cd instances/dss15-orcl21
docker compose up -d
```

Open `http://localhost:10000`, with the instance's port. View the startup logs
with `docker compose logs -f dss`, and stop the instance with
`docker compose down`. Its data stays in its volume: `docker compose down`
keeps it, `docker compose down --volumes` deletes it. Every
`docker compose up` rebuilds the image from cache (`pull_policy: build`), so
changes to the instance's `compose.yaml` or to the scripts apply at the next
start.

The image has a healthcheck: `docker compose ps` shows the container as
`healthy` once the DSS backend answers on `/dip/api/ping`. It stays `starting`
while DSS is being installed or started, which can take several minutes, and
turns `unhealthy` if the backend stops answering.

A fresh data directory has the DSS default `admin` / `admin` login. Change the
password at first login. The container has `no-new-privileges` enabled, and
Docker retries failed container starts up to three times.

## One volume, one DSS version

A data directory belongs to the DSS version that created it. When an instance
starts on a volume created by another DSS version, the container refuses to
start and logs both versions, instead of letting DSS's own startup upgrade the
data. To use another DSS version, create another instance, or delete the volume
with `docker compose down --volumes` to start the instance fresh.

## JDBC drivers

The image can include the Oracle and Trino JDBC drivers. They are downloaded
from Maven Central when the image is built, and each jar is checked against the
SHA-256 checksum Maven Central publishes for it.

| Setting | Default | Jars | Installed in the data directory at |
|---|---|---|---|
| `ORACLE_JDBC_VERSION` | `21.24.0.0`, the latest Oracle 21c driver | `ojdbc11-<version>.jar`, `orai18n-<version>.jar` | `lib/jdbc/` |
| `TRINO_JDBC_VERSION` | `484`, the latest Trino driver | `trino-jdbc-<version>.jar` | `lib/jdbc/trino/` |

Both drivers are optional: set a version to empty in the instance's
`compose.yaml` (`TRINO_JDBC_VERSION: ""`) to leave that driver out. The new
versions apply at the next `docker compose up`.

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
- The base image's `/home/dataiku/run.sh` initializes the data directory and
  then immediately `exec`s `dss run`, with no hook in between.
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
   silently ignored with a new base image.
2. At container start, [`start-dss.sh`](start-dss.sh) checks that the license
   file, when present, is readable JSON, checks the data directory version
   (see [One volume, one DSS version](#one-volume-one-dss-version)), runs
   `dss-init.sh` (install on an empty volume, nothing otherwise), installs the
   [JDBC drivers](#jdbc-drivers), copies the license to `config/license.json`
   when it differs, then `exec`s `dss run`.

DSS starts once, already licensed: there is no API polling and no restart.

The `license/` folder at the root of the repository is bind-mounted read-only
at `/home/dataiku/license` in every instance, outside the data directory. A folder is mounted rather than the file itself so
that the license stays optional: Docker cannot mount a single file that may not
exist. Set `DSS_LICENSE_FILE` on the service to read the license from another
path inside the container.

When `license/license.json` is present, it is the source of truth: it overwrites
`config/license.json` on every start, so a license entered in the DSS UI is
replaced at the next start. After adding or updating it, restart the
instances, from each instance's folder:

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
  are in `scripts/smoke-checks/`. It takes several minutes per base image.
  Without arguments it tests the base images the instances use; otherwise pass
  base images, with or without a digest:

  ```bash
  scripts/smoke-test.sh dataiku/dss:13.4.4 dataiku/dss:15.2.0
  ```

  It builds with the default JDBC drivers, uses host port 10100
  (`SMOKE_PORT`) and its own project and image, `dss-smoke-<version>`, deleted
  at the end, so it can run next to a running instance without touching it.
  `--keep` leaves the test project in place for inspection.

Run both before changing a base image or the scripts: the base images differ
between DSS versions, down to the tools they include.

`.gitattributes` keeps LF line endings in the working tree on Windows: the
scripts run in Linux containers, where CRLF line endings break them.

## License and image usage

Keep the license file at `license/license.json`. It is ignored by Git and
excluded from the build context.

The public `dataiku/dss` Docker Hub image is described as intended for evaluation
and not production use. Dataiku also warns that running DSS in a container is
unsupported and generally incompatible with using containers as a processing
engine. Consult your Dataiku account team before using this deployment model:
[Dataiku container installation guidance](https://doc.dataiku.com/dss/latest/installation/other/container.html).
