# Dataiku DSS Docker bootstrap

[![Lint](https://github.com/Zyniel/dss-docker-bootstrap/actions/workflows/lint.yml/badge.svg)](https://github.com/Zyniel/dss-docker-bootstrap/actions/workflows/lint.yml)

Local Dataiku DSS test servers with Docker Compose, built on the official
`dataiku/dss` image, with optional JDBC drivers and license installed at startup.

> Independent project, not affiliated with or endorsed by Dataiku. It contains
> no Dataiku software.

## Features

- One Compose file per instance, on top of a shared base
- Oracle and Trino JDBC drivers, optional, checksum-verified at build time
- DSS license, optional, installed before DSS starts
- Refuses to start on a data volume from another DSS version
- Healthcheck, non-root user, port bound to `127.0.0.1`

## Requirements

- Docker with Compose v2 (Docker Desktop or Docker Engine)
- Bash for the scripts in `scripts/` (Git Bash on Windows)
- Optionally, a Dataiku DSS license file

## Quick start

```shell
cp /path/to/license.json license/license.json   # optional
cd instances/dss15-orcl21
docker compose up -d
```

Open <http://localhost:10000> (or the instance's
[host port](#host-port)) once `docker compose ps` reports `healthy` (a first
start takes a few minutes). A new instance's login is `admin` / `admin`:
change it at first login.

## Layout

```
image/              Dockerfile and startup scripts
compose.base.yaml   settings shared by all instances
instances/<name>/   one compose.yaml per instance, and an optional .env
license/            license.json, shared by all instances (ignored by Git)
scripts/            lint and smoke test
```

## Instances

An instance is a folder in `instances/` holding a `compose.yaml`:

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

volumes:
  dss-data:
```

| Setting | Description | Default |
|---|---|---|
| `DSS_BASE_IMAGE` | [`dataiku/dss`](https://hub.docker.com/r/dataiku/dss/tags) version tag, optionally pinned with `@<digest>` | `dataiku/dss:13.4.4` |
| `ORACLE_JDBC_VERSION` | `ojdbc11` and `orai18n` version, `""` to skip | `21.24.0.0` |
| `TRINO_JDBC_VERSION` | `trino-jdbc` version, `""` to skip | `484` |

- The folder name is the Compose project name: it names the container, the
  image (`<name>-dss`) and the data volume (`<name>_dss-data`).
- The `volumes` block is required.
- To add an instance, copy a folder and change its settings.
- A digest is printed by `docker buildx imagetools inspect dataiku/dss:<tag>`.
  The build fails if the tag does not match the DSS version in the image.

### Host port

DSS is published on `127.0.0.1:${DSS_HOST_PORT:-10000}`. To run instances side
by side, give each its own port in a `.env` file in its folder (ignored by Git):

```shell
echo DSS_HOST_PORT=10001 > instances/<name>/.env
```

A `DSS_HOST_PORT` set in the shell takes precedence over the `.env` file.
Inside the container, DSS always listens on 10000.

## Usage

From the instance's folder:

| Task | Command |
|---|---|
| Start, or apply changes | `docker compose up -d` |
| Status | `docker compose ps` |
| Logs | `docker compose logs -f dss` |
| Reload the license | `docker compose restart dss` |
| Stop | `docker compose down` |
| Delete the data | `docker compose down --volumes` |

## Behavior

- **DSS version**: a data volume is bound to the DSS version that created it.
  On a mismatch, the container exits. [More](docs/instances.md#change-the-dss-version)
- **License**: `license/license.json` is installed at each start and replaces
  any license entered in the DSS UI. Without one, DSS runs in free mode.
  [More](docs/license.md)
- **JDBC drivers**: Oracle connections use the driver as is. Trino connections
  must be set to the "User provided" driver mode, with `lib/jdbc/trino` as
  driver directory. [More](docs/jdbc-drivers.md)

## Documentation

- [How it works](docs/how-it-works.md): build, startup sequence, runtime settings
- [Instances](docs/instances.md): create, pin, change version, remove
- [JDBC drivers](docs/jdbc-drivers.md): installation and use in DSS
- [License](docs/license.md): installation, behavior, Linux permissions
- [Development](docs/development.md): lint, smoke test, conventions
- [Troubleshooting](docs/troubleshooting.md): error messages and fixes

## Development

```shell
scripts/lint.sh                                          # ShellCheck and Hadolint
scripts/smoke-test.sh [--keep] [dataiku/dss:<tag>...]   # end-to-end test
```

See [Development](docs/development.md).

## Disclaimer

The public `dataiku/dss` image is intended for evaluation, not production, and
Dataiku does not support running DSS in containers; see
[Dataiku's container guidance](https://doc.dataiku.com/dss/latest/installation/other/container.html).
Dataiku and Dataiku DSS are trademarks of Dataiku.

## License

[MIT](LICENSE.txt), for the files in this repository only. Dataiku DSS, its
images and the JDBC drivers keep their own licenses.
