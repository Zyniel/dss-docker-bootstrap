#!/bin/bash
# Runs inside the DSS container, started by smoke-test.sh.
#
# Checks that every JDBC driver jar built into the image was copied, unchanged,
# into the DSS data directory, and that the list start-dss.sh keeps of the jars
# it installed (the manifest) names exactly those jars. Prints the jars found,
# or "none".
set -euo pipefail

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
# content: two files with the same checksum have the same content.
# "<<<" passes the text in $jars to the loop, which reads it one line at a time.
while read -r jar; do
    if [[ ! -f "$target_dir/$jar" ]]; then
        echo "missing: lib/jdbc/$jar"
        exit 1
    fi
    if [[ "$(sha256sum <"$source_dir/$jar")" != "$(sha256sum <"$target_dir/$jar")" ]]; then
        echo "different from the image: lib/jdbc/$jar"
        exit 1
    fi
done <<<"$jars"

if [[ ! -f "$manifest" ]]; then
    echo "no manifest in lib/jdbc"
    exit 1
fi
if [[ "$(cat "$manifest")" != "$jars" ]]; then
    echo "the manifest does not list the image's jars"
    exit 1
fi

# Print the jars on one line: tr replaces each line break with a space.
echo "$jars" | tr '\n' ' '
