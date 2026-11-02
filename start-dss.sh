#!/bin/bash
# Container start command (see Dockerfile): checks the license and the data
# directory version, prepares the data directory, installs the JDBC drivers and
# the license, then starts DSS.
set -euo pipefail

LICENSE_FILE=${DSS_LICENSE_FILE:-/home/dataiku/license/license.json}
LICENSE_TARGET=$DSS_DATADIR/config/license.json
JDBC_SOURCE=/home/dataiku/jdbc-drivers
JDBC_TARGET=$DSS_DATADIR/lib/jdbc
JDBC_MANIFEST=$JDBC_TARGET/.dss-bootstrap-drivers

# same_file A B: true when both files exist with identical content. Uses
# sha256sum rather than cmp, which some dataiku/dss images (13.4.4) lack.
same_file() {
    [[ -f "$1" && -f "$2" ]] && [[ "$(sha256sum <"$1")" == "$(sha256sum <"$2")" ]]
}

# Fail before touching anything if a license is provided but unusable.
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

# A data directory belongs to the DSS version that created it. dss-init.sh
# would upgrade one from an older DSS, which cannot be undone, and wrongly
# restamp one from a newer DSS. These are local test servers, where another
# version means another instance: refuse to start instead.
if [[ -f "$DSS_DATADIR/dss-version.json" ]]; then
    data_version=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["product_version"])' "$DSS_DATADIR/dss-version.json")
    if [[ "$data_version" != "$DSS_VERSION" ]]; then
        echo "[-] This volume holds DSS $data_version data, but this image runs DSS $DSS_VERSION. Use an instance with DSS $data_version, or delete the volume (docker compose down --volumes) to start fresh" >&2
        exit 1
    fi
fi

# Install DSS on an empty data directory, or leave it as is (upstream run.sh
# logic).
/home/dataiku/dss-init.sh

# Sync the JDBC drivers built into the image into lib/jdbc. The manifest lists
# the jars installed by the previous start, so jars from an old version or a
# disabled driver are removed. Jars added to lib/jdbc by hand are left alone.
mkdir -p "$JDBC_TARGET"
mapfile -t jdbc_jars < <(cd "$JDBC_SOURCE" && find . -name '*.jar' -printf '%P\n' | sort)
declare -A jdbc_wanted=()
for jar in "${jdbc_jars[@]}"; do
    jdbc_wanted[$jar]=1
done

if [[ -f "$JDBC_MANIFEST" ]]; then
    while IFS= read -r jar; do
        if [[ -n "$jar" && -z "${jdbc_wanted[$jar]:-}" ]]; then
            echo "[+] Removing JDBC driver $JDBC_TARGET/$jar"
            rm -f "$JDBC_TARGET/$jar"
        fi
    done <"$JDBC_MANIFEST"
fi

for jar in "${jdbc_jars[@]}"; do
    if ! same_file "$JDBC_SOURCE/$jar" "$JDBC_TARGET/$jar"; then
        echo "[+] Installing JDBC driver $JDBC_TARGET/$jar"
        install -D -m 644 "$JDBC_SOURCE/$jar" "$JDBC_TARGET/$jar"
    fi
done

if (( ${#jdbc_jars[@]} )); then
    printf '%s\n' "${jdbc_jars[@]}" >"$JDBC_MANIFEST"
    echo "[+] JDBC drivers in place: ${jdbc_jars[*]}"
else
    rm -f "$JDBC_MANIFEST"
    echo "[+] No JDBC drivers built into this image"
fi

# Install the license, or warn when there is none.
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

exec "$DSS_DATADIR/bin/dss" run
