# JDBC drivers

## Drivers

| Setting | Default | Jars | Installed in |
|---|---|---|---|
| `ORACLE_JDBC_VERSION` | `21.24.0.0` (latest Oracle 21c) | `ojdbc11`, `orai18n` | `lib/jdbc/` |
| `TRINO_JDBC_VERSION` | `484` | `trino-jdbc` | `lib/jdbc/trino/` |

- Set a version to `""` in the instance's `compose.yaml` to leave the driver
  out.
- Changes apply at the next `docker compose up`.

## Build and install

1. At build time, the jars are downloaded from Maven Central and checked
   against the SHA-256 checksum published next to each one.
2. They are stored in the image, in `/home/dataiku/jdbc-drivers`. They cannot
   go into the data directory at build time: the DSS installer needs it empty,
   and the volume is mounted over it.
3. At each start, they are copied into the data directory's `lib/jdbc`.
   `lib/jdbc/.dss-bootstrap-drivers` lists the jars installed, so that:
   - jars from a previous version, or from a driver left out, are removed;
   - jars added to `lib/jdbc` by hand are left alone.

Do not add other versions of these two drivers by hand: two versions on the
classpath conflict.

## Use them in DSS

**Oracle.** `lib/jdbc` is on the DSS classpath: Oracle connections use the
driver with no setting. `ojdbc11` supports Java 11 and later (DSS runs on Java
17); `orai18n` adds the character sets some databases need.

**Trino.** DSS bundles its own Trino driver, and connections use it by default.
The driver installed here is in its own folder, off the classpath, so the two do
not conflict. To use it, set the connection to:

- driver mode: **User provided**
- driver directory: `lib/jdbc/trino`

Through the DSS API, these are the connection parameters:

```json
{
  "driverMode": "CUSTOM",
  "jarsDirectory": "lib/jdbc/trino"
}
```

Use a driver version equal to or newer than the Trino cluster's. See
[Dataiku's Trino documentation](https://doc.dataiku.com/dss/latest/connecting/sql/trino.html).

## Check

```shell
docker compose logs dss | grep JDBC
```

```text
[+] JDBC drivers in place: ojdbc11-21.24.0.0.jar orai18n-21.24.0.0.jar trino/trino-jdbc-484.jar
```
