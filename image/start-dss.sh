#!/bin/bash
# Starts DSS:
#   1. checks the license, if one is provided;
#   2. checks that the data directory is from this image's DSS version;
#   3. installs DSS in the data directory if it is empty;
#   4. installs the JDBC drivers built into the image;
#   5. installs the license;
#   6. runs DSS.
#
# Runs at container start: it is the image's command (see Dockerfile). The base
# image sets DSS_DATADIR, the data directory (the instance's volume), and
# DSS_VERSION. Messages use the DSS installer's prefixes: [+] progress,
# [!] warning, [-] error.
set -euo pipefail # stop at the first failing command, unset variable or failed pipe

LICENSE_FILE=${DSS_LICENSE_FILE:-/home/dataiku/license/license.json}
LICENSE_TARGET=$DSS_DATADIR/config/license.json
JDBC_SOURCE=/home/dataiku/jdbc-drivers
JDBC_TARGET=$DSS_DATADIR/lib/jdbc
# The list of the jars this script installed in lib/jdbc, kept there.
JDBC_MANIFEST=$JDBC_TARGET/.dss-bootstrap-drivers

# same_file A B: succeeds when both files exist and have the same content, that
# is the same SHA-256 checksum (cmp would do, but some dataiku/dss images, such
# as 13.4.4, do not include it). set -e does not apply in a function called
# from an if, hence the explicit "|| return 1" when a checksum fails.
same_file() {
    local sum_a
    local sum_b
    if [[ ! -f "$1" || ! -f "$2" ]]; then
        return 1
    fi
    sum_a=$(sha256sum <"$1") || return 1
    sum_b=$(sha256sum <"$2") || return 1
    [[ "$sum_a" == "$sum_b" ]]
}

# 1. A license that is provided but unusable stops the start, before anything
# is changed. Python's json module tells whether the file is valid JSON.
if [[ -e "$LICENSE_FILE" ]]; then
    if [[ ! -f "$LICENSE_FILE" || ! -r "$LICENSE_FILE" ]]; then
        echo "[-] DSS license path $LICENSE_FILE is not a readable file" >&2
        exit 1
    fi
    if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$LICENSE_FILE" 2>/dev/null; then
        echo "[-] DSS license file $LICENSE_FILE is not valid JSON" >&2
        exit 1
    fi
fi

# 2. A data directory belongs to the DSS version that created it. DSS's own
# startup (step 3) would upgrade one from an older DSS, which cannot be undone,
# and wrongly restamp one from a newer DSS. These are local test servers, where
# another version means another instance: refuse to start instead.
if [[ -f "$DSS_DATADIR/dss-version.json" ]]; then
    data_version=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["product_version"])' "$DSS_DATADIR/dss-version.json")
    if [[ "$data_version" != "$DSS_VERSION" ]]; then
        echo "[-] This volume holds DSS $data_version data, but this image runs DSS $DSS_VERSION. Use an instance with DSS $data_version, or delete the volume (docker compose down --volumes) to start fresh" >&2
        exit 1
    fi
fi

# 3. Install DSS in an empty data directory, or leave it as is: the base
# image's own startup script without its last line, which starts DSS (see
# Dockerfile).
/home/dataiku/dss-init.sh

# 4. Copy the JDBC drivers built into the image into lib/jdbc, and remove those
# a previous start installed that the image no longer has (an older version, or
# a driver now left out). Jars added to lib/jdbc by hand are left alone.

# The jars in the image, one per line, as paths relative to JDBC_SOURCE, for
# example "ojdbc11-21.24.0.0.jar" and "trino/trino-jdbc-484.jar".
jdbc_jars=$(cd "$JDBC_SOURCE" && find . -name '*.jar' -printf '%P\n' | sort)
mkdir -p "$JDBC_TARGET"

# "while read" handles one line at a time, from the file given with "<". grep
# -q -x -F succeeds when the exact line is in the text given with "<<<".
if [[ -f "$JDBC_MANIFEST" ]]; then
    while read -r jar; do
        if [[ -n "$jar" ]] && ! grep -q -x -F "$jar" <<<"$jdbc_jars"; then
            echo "[+] Removing JDBC driver $JDBC_TARGET/$jar"
            rm -f "$JDBC_TARGET/$jar"
        fi
    done <"$JDBC_MANIFEST"
fi

if [[ -z "$jdbc_jars" ]]; then
    rm -f "$JDBC_MANIFEST"
    echo "[+] No JDBC drivers built into this image"
else
    while read -r jar; do
        if ! same_file "$JDBC_SOURCE/$jar" "$JDBC_TARGET/$jar"; then
            echo "[+] Installing JDBC driver $JDBC_TARGET/$jar"
            # -D creates the missing folders (trino/), -m 644 makes the copy
            # readable by all.
            install -D -m 644 "$JDBC_SOURCE/$jar" "$JDBC_TARGET/$jar"
        fi
    done <<<"$jdbc_jars"
    echo "$jdbc_jars" >"$JDBC_MANIFEST"
    # printf '%s' prints the list without a final line break, and tr turns the
    # line breaks between the jars into spaces.
    echo "[+] JDBC drivers in place: $(printf '%s' "$jdbc_jars" | tr '\n' ' ')"
fi

# 5. Install the license, or warn when there is none.
if [[ ! -e "$LICENSE_FILE" ]]; then
    if [[ -f "$LICENSE_TARGET" ]]; then
        echo "[!] No DSS license file at $LICENSE_FILE; keeping the license already installed in $LICENSE_TARGET" >&2
    else
        echo "[!] No DSS license file at $LICENSE_FILE; DSS will run in its default free mode" >&2
    fi
elif same_file "$LICENSE_FILE" "$LICENSE_TARGET"; then
    echo "[+] DSS license is up to date"
else
    echo "[+] Installing DSS license from $LICENSE_FILE"
    install -m 600 "$LICENSE_FILE" "$LICENSE_TARGET"
fi

# 6. Run DSS. exec replaces this script with DSS, so that DSS receives the
# container's stop signal directly.
exec "$DSS_DATADIR/bin/dss" run
