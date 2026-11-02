#!/bin/bash
# Checks that every JDBC driver jar built into the image was copied, unchanged,
# into the DSS data directory, and that start-dss.sh's manifest, its list of
# the jars it installed, names exactly those jars. Prints the jars, or "none".
#
# Runs inside the DSS container, from scripts/smoke-test.sh.
set -euo pipefail # stop at the first failing command, unset variable or failed pipe

source_dir=/home/dataiku/jdbc-drivers
target_dir=$DSS_DATADIR/lib/jdbc
manifest=$target_dir/.dss-bootstrap-drivers

# The jars in the image, one per line, as paths relative to source_dir, for
# example "ojdbc11-21.24.0.0.jar" and "trino/trino-jdbc-484.jar".
jars=$(cd "$source_dir" && find . -name '*.jar' -printf '%P\n' | sort)

if [[ -z "$jars" ]]; then
    # No drivers in the image: start-dss.sh must not have left a manifest.
    if [[ -e "$manifest" ]]; then
        echo "a manifest is left with no jars in the image"
        exit 1
    fi
    echo "none"
    exit 0
fi

# Compare each jar with its copy. sha256sum prints a checksum of the file's
# content: two files with the same checksum have the same content. "while read"
# handles one line at a time, from the text given with "<<<".
while read -r jar; do
    if [[ ! -f "$target_dir/$jar" ]]; then
        echo "missing: lib/jdbc/$jar"
        exit 1
    fi
    source_sum=$(sha256sum <"$source_dir/$jar")
    target_sum=$(sha256sum <"$target_dir/$jar")
    if [[ "$source_sum" != "$target_sum" ]]; then
        echo "different from the image: lib/jdbc/$jar"
        exit 1
    fi
done <<<"$jars"

if [[ ! -f "$manifest" ]]; then
    echo "no manifest in lib/jdbc"
    exit 1
fi
listed=$(cat "$manifest")
if [[ "$listed" != "$jars" ]]; then
    echo "the manifest does not list the image's jars"
    exit 1
fi

# printf '%s' prints the list without a final line break, and tr turns the
# line breaks between the jars into spaces.
printf '%s' "$jars" | tr '\n' ' '
