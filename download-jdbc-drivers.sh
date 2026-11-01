#!/bin/bash
# Build-time helper, run by the Dockerfile: downloads the JDBC drivers selected
# by the ORACLE_JDBC_VERSION and TRINO_JDBC_VERSION build arguments from Maven
# Central, and checks each jar against the SHA-256 published next to it.
# An empty version skips that driver.
#
# The output directory mirrors DSS_DATADIR/lib/jdbc, where start-dss.sh copies
# it at container start:
#   ojdbc11-<version>.jar, orai18n-<version>.jar   directly in lib/jdbc, which
#                                                  is on the DSS classpath
#   trino/trino-jdbc-<version>.jar                 in lib/jdbc/trino, used by
#                                                  Trino connections set to the
#                                                  "User provided" driver mode
set -euo pipefail

MAVEN_CENTRAL=https://repo1.maven.org/maven2
DRIVERS_DIR=${1:?usage: $0 OUTPUT_DIR}

# download GROUP_PATH ARTIFACT VERSION DEST_DIR
download() {
    local url="$MAVEN_CENTRAL/$1/$2/$3/$2-$3.jar"
    local jar="$4/$2-$3.jar"
    local expected actual

    echo "+ Downloading $url"
    mkdir -p "$4"
    if ! curl -fsSL --retry 3 -o "$jar" "$url"; then
        echo "Cannot download $url; check that version $3 of $2 exists on Maven Central" >&2
        exit 1
    fi

    expected=$(curl -fsSL --retry 3 "$url.sha256" | tr -d '[:space:]')
    expected=${expected:0:64}
    actual=$(sha256sum "$jar" | cut -d' ' -f1)
    if [[ "$actual" != "$expected" ]]; then
        echo "SHA-256 mismatch for $jar: expected $expected, got $actual" >&2
        exit 1
    fi
}

mkdir -p "$DRIVERS_DIR"

if [[ -n "${ORACLE_JDBC_VERSION:-}" ]]; then
    # ojdbc11 targets Java 11 and later; DSS runs on Java 17. orai18n adds the
    # character sets ojdbc11 does not include on its own.
    download com/oracle/database/jdbc ojdbc11 "$ORACLE_JDBC_VERSION" "$DRIVERS_DIR"
    download com/oracle/database/nls orai18n "$ORACLE_JDBC_VERSION" "$DRIVERS_DIR"
else
    echo "+ ORACLE_JDBC_VERSION is empty, skipping the Oracle JDBC driver"
fi

if [[ -n "${TRINO_JDBC_VERSION:-}" ]]; then
    download io/trino trino-jdbc "$TRINO_JDBC_VERSION" "$DRIVERS_DIR/trino"
else
    echo "+ TRINO_JDBC_VERSION is empty, skipping the Trino JDBC driver"
fi
