#!/bin/bash
# Container start command (see Dockerfile): checks the license and the data
# directory version, prepares the data directory (backing it up before an
# upgrade), installs the JDBC drivers and the license, then starts DSS.
set -euo pipefail

LICENSE_FILE=${DSS_LICENSE_FILE:-/home/dataiku/license/license.json}
LICENSE_TARGET=$DSS_DATADIR/config/license.json
JDBC_SOURCE=/home/dataiku/jdbc-drivers
JDBC_TARGET=$DSS_DATADIR/lib/jdbc
JDBC_MANIFEST=$JDBC_TARGET/.dss-bootstrap-drivers
BACKUP_DIR=${DSS_BACKUP_DIR:-/home/dataiku/backups}

# same_file A B: true when both files exist with identical content. Uses
# sha256sum rather than cmp, which some dataiku/dss images (13.4.4) lack.
same_file() {
    [[ -f "$1" && -f "$2" ]] && [[ "$(sha256sum <"$1")" == "$(sha256sum <"$2")" ]]
}

# backup_data_dir VERSION: saves the whole data directory, last used by DSS
# VERSION, to a .tar.gz in BACKUP_DIR. DSS is not running yet, so the copy is
# consistent. BACKUP_DIR must already exist: it is meant to be a mount, and a
# folder created here would be lost with the container.
backup_data_dir() {
    local backup
    if [[ ! -d "$BACKUP_DIR" || ! -w "$BACKUP_DIR" ]]; then
        echo "[-] Cannot back up the data directory before upgrading it: $BACKUP_DIR is not a writable directory" >&2
        exit 1
    fi
    backup=$BACKUP_DIR/dss-data-$1-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
    echo "[+] Backing up the data directory (DSS $1) to $backup"
    if ! tar -czf "$backup.partial" -C "$DSS_DATADIR" .; then
        rm -f "$backup.partial"
        echo "[-] Backup failed; the data directory was not upgraded" >&2
        exit 1
    fi
    mv "$backup.partial" "$backup"
    echo "[+] Backup saved ($(du -h "$backup" | cut -f 1)); upgrading the data directory to DSS $DSS_VERSION"
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

# Compare the DSS version of an existing data directory with this image's.
if [[ -f "$DSS_DATADIR/dss-version.json" ]]; then
    data_version=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["product_version"])' "$DSS_DATADIR/dss-version.json")
    newest=$(printf '%s\n' "$data_version" "$DSS_VERSION" | sort -V | tail -n 1)

    # DSS can upgrade a data directory but not downgrade one, and its installer
    # does not check: on a newer data directory it finds no migration to run and
    # still stamps it with the older version. Refuse to start instead.
    if [[ "$data_version" != "$DSS_VERSION" && "$newest" == "$data_version" ]]; then
        echo "[-] The data directory is from DSS $data_version, newer than this image's DSS $DSS_VERSION; DSS cannot downgrade a data directory" >&2
        exit 1
    fi

    # dss-init.sh upgrades an older data directory in place, without asking,
    # and the upgrade cannot be undone. Only let it run when DSS_ALLOW_UPGRADE
    # names this image's version, so that changing DSS_VERSION alone never
    # upgrades, and back up the data directory first.
    if [[ "$data_version" != "$DSS_VERSION" ]]; then
        if [[ "${DSS_ALLOW_UPGRADE:-}" != "$DSS_VERSION" ]]; then
            echo "[-] The data directory is from DSS $data_version; starting this image would upgrade it to DSS $DSS_VERSION, which cannot be undone" >&2
            echo "[-] To upgrade, set DSS_ALLOW_UPGRADE=$DSS_VERSION; the data directory is backed up to $BACKUP_DIR first. To stay on DSS $data_version, use DSS_VERSION=$data_version with its DSS_IMAGE_DIGEST" >&2
            exit 1
        fi
        backup_data_dir "$data_version"
    fi
fi

# Install, upgrade or leave the data directory as is (upstream run.sh logic).
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
