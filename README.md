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

Copy `.env.example` to `.env`, then set the desired DSS image tag, host port and
JDBC driver versions:

```dotenv
DSS_VERSION=13.4.4
DSS_PORT=10000
ORACLE_JDBC_VERSION=21.24.0.0
TRINO_JDBC_VERSION=484
```

`DSS_VERSION` must be a tag published for
[`dataiku/dss`](https://hub.docker.com/r/dataiku/dss/tags) on Docker Hub. Not
every DSS release has one. The JDBC driver versions are described in
[JDBC drivers](#jdbc-drivers).

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
volume. Rebuild the custom image after changing the DSS version or startup
wrapper with `docker compose up --build -d`.

The container listens only on `127.0.0.1` by default and has
`no-new-privileges` enabled. Docker retries failed container starts up to three
times.

Back up the `dss-data` Docker volume before changing `DSS_VERSION`: the image
upgrades an existing DSS data directory when started with a newer version.
`docker compose down` preserves the volume; `docker compose down --volumes`
deletes it.

DSS cannot downgrade a data directory, and its installer does not check for
it. So the container refuses to start when the data directory was created by a
newer DSS than the image runs, and logs both versions. To go back to an older
version, start from a new, empty volume.

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
   file, when present, is readable JSON, runs `dss-init.sh` (install on an
   empty volume, upgrade when the DSS version changed, nothing otherwise),
   installs the [JDBC drivers](#jdbc-drivers), copies the license to
   `config/license.json` when it differs, then `exec`s `dss run`.

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

## License and image usage

Keep the license file at `license/license.json`. It is ignored by Git and
excluded from the build context, as is `.env`.

The public `dataiku/dss` Docker Hub image is described as intended for evaluation
and not production use. Dataiku also warns that running DSS in a container is
unsupported and generally incompatible with using containers as a processing
engine. Consult your Dataiku account team before using this deployment model:
[Dataiku container installation guidance](https://doc.dataiku.com/dss/latest/installation/other/container.html).
