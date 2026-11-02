# Instances

An instance is a DSS server: a folder in `instances/` with a `compose.yaml`
that extends [`compose.base.yaml`](../compose.base.yaml).

## Names

The folder name is the Compose project name, which names everything else:

| Resource | Name |
|---|---|
| Container | `<name>-dss-1` |
| Image | `<name>-dss` |
| Data volume | `<name>_dss-data` |

- Use lowercase letters, digits and dashes.
- Renaming the folder starts a new, empty instance. The old volume stays until
  deleted.

## Create an instance

```shell
cp -r instances/dss15-orcl21 instances/dss13-trino
```

Then edit `instances/dss13-trino/compose.yaml`:

```yaml
services:
  dss:
    extends:
      file: ../../compose.base.yaml
      service: dss
    build:
      args:
        DSS_BASE_IMAGE: dataiku/dss:13.4.4
        ORACLE_JDBC_VERSION: ""
        TRINO_JDBC_VERSION: "484"
    ports:
      - "127.0.0.1:10001:10000"   # a free host port

volumes:
  dss-data:   # required: extends does not carry it over
```

Several instances can run side by side, each on its own host port.

## Pin the base image

A tag can be pushed again upstream. A digest pins the exact image:

```shell
docker buildx imagetools inspect dataiku/dss:15.2.0
```

```yaml
DSS_BASE_IMAGE: dataiku/dss:15.2.0@sha256:04b18e413e617d6485c317737228a6b16dcd899f815ee2a626c2b2b0e428582f
```

- With a digest, Docker ignores the tag. The build checks that the tag is the
  DSS version in the image, and fails otherwise.
- Not every DSS release is published as a
  [`dataiku/dss` tag](https://hub.docker.com/r/dataiku/dss/tags).

## Change the DSS version

A data volume is bound to the DSS version that created it. On a mismatch, the
container stops with:

```text
[-] This volume holds DSS 13.4.4 data, but this image runs DSS 15.2.0. Use an instance with DSS 13.4.4, or delete the volume (docker compose down --volumes) to start fresh
```

DSS's own startup would otherwise upgrade the data in place, which cannot be
undone. To use another version, either:

- create another instance, and keep the current one; or
- start the instance fresh, which deletes its data:

  ```shell
  docker compose down --volumes
  # edit DSS_BASE_IMAGE in compose.yaml
  docker compose up -d
  ```

## Remove an instance

From its folder, then delete the folder:

```shell
docker compose down --volumes --rmi all
```
