#!/bin/bash
# Downloads the JDBC drivers selected by ORACLE_JDBC_VERSION and
# TRINO_JDBC_VERSION from Maven Central into OUTPUT_DIR, and checks each jar
# against the SHA-256 checksum published next to it. An empty version skips
# that driver.
#
# Runs at image build, from the Dockerfile, which passes both versions as build
# arguments. OUTPUT_DIR mirrors lib/jdbc in the DSS data directory, where
# start-dss.sh copies it at container start:
#   ojdbc11-<version>.jar, orai18n-<version>.jar   in lib/jdbc, which is on the
#                                                  DSS classpath
#   trino/trino-jdbc-<version>.jar                 in lib/jdbc/trino, for Trino
#                                                  connections set to the "User
#                                                  provided" driver mode
#
# Usage: download-jdbc-drivers.sh OUTPUT_DIR
set -euo pipefail # stop at the first failing command, unset variable or failed pipe

MAVEN_CENTRAL=https://repo1.maven.org/maven2
# ${1:?message} is the first argument, or an error with that message without one.
OUTPUT_DIR=${1:?usage: $0 OUTPUT_DIR}

# download GROUP_PATH ARTIFACT VERSION DEST_DIR: downloads ARTIFACT-VERSION.jar
# from Maven Central into DEST_DIR, then checks its checksum.
download() {
    local group_path=$1
    local artifact=$2
    local version=$3
    local dest_dir=$4
    local url=$MAVEN_CENTRAL/$group_path/$artifact/$version/$artifact-$version.jar
    local jar=$dest_dir/$artifact-$version.jar
    local expected
    local actual

    echo "[+] Downloading $url"
    mkdir -p "$dest_dir"
    if ! curl -fsSL --retry 3 -o "$jar" "$url"; then
        echo "[-] Cannot download $url; check that version $version of $artifact exists on Maven Central" >&2
        exit 1
    fi

    # The .sha256 file holds the checksum, sometimes followed by the file name:
    # once spaces and line breaks are removed, the checksum is the first 64
    # characters.
    if ! expected=$(curl -fsSL --retry 3 "$url.sha256" | tr -d '[:space:]'); then
        echo "[-] Cannot download $url.sha256" >&2
        exit 1
    fi
    expected=${expected:0:64}
    actual=$(sha256sum "$jar" | cut -d ' ' -f 1)
    if [[ "$actual" != "$expected" ]]; then
        echo "[-] SHA-256 mismatch for $jar: expected $expected, got $actual" >&2
        exit 1
    fi
}

# Created even without any driver: start-dss.sh lists what it contains.
mkdir -p "$OUTPUT_DIR"

# ${NAME:-} is empty when NAME is unset, which set -u would otherwise reject.
if [[ -n "${ORACLE_JDBC_VERSION:-}" ]]; then
    # ojdbc11 targets Java 11 and later; DSS runs on Java 17. orai18n adds the
    # character sets ojdbc11 does not include on its own.
    download com/oracle/database/jdbc ojdbc11 "$ORACLE_JDBC_VERSION" "$OUTPUT_DIR"
    download com/oracle/database/nls orai18n "$ORACLE_JDBC_VERSION" "$OUTPUT_DIR"
else
    echo "[+] ORACLE_JDBC_VERSION is empty: no Oracle JDBC driver"
fi

if [[ -n "${TRINO_JDBC_VERSION:-}" ]]; then
    download io/trino trino-jdbc "$TRINO_JDBC_VERSION" "$OUTPUT_DIR/trino"
else
    echo "[+] TRINO_JDBC_VERSION is empty: no Trino JDBC driver"
fi
