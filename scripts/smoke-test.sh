#!/bin/bash
# Smoke test of the image, for each DSS version given:
#   1. builds the image with Docker Compose;
#   2. checks that the container refuses to start, before changing anything,
#      with an unusable license or a data directory from another DSS version;
#   3. starts it on a fresh volume and waits for the healthcheck;
#   4. checks the startup logs, the JDBC drivers and the license;
#   5. restarts it and checks that nothing is installed again.
# Each version runs in a throwaway Compose project, dss-smoke-<version>, removed
# with its volumes at the end (unless --keep). The image built is the one
# docker-compose.yml uses, dss-docker-bootstrap:<version>. A license in
# license/license.json is used, and must then be accepted by DSS.
#
# Usage: scripts/smoke-test.sh [--keep] [VERSION[@DIGEST]...]
#   VERSION         a dataiku/dss tag, built from the tag alone
#   VERSION@DIGEST  the same, pinned to that digest
#   (none)          the version and digest docker-compose.yml resolves, from
#                   .env or its defaults
# Environment: SMOKE_PORT (host port, default 10100), SMOKE_TIMEOUT (seconds to
# wait for DSS to be healthy, default 1200).
set -euo pipefail

# Git Bash on Windows rewrites arguments that look like paths; keep them as is.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

SMOKE_PORT=${SMOKE_PORT:-10100}
SMOKE_TIMEOUT=${SMOKE_TIMEOUT:-1200}

keep=false
if [[ "${1:-}" == "--keep" ]]; then
    keep=true
    shift
fi

project=
image=

log() { echo "[smoke] $*"; }

compose() { docker compose -p "$project" "$@"; }

fail() {
    echo "[smoke] FAIL: $*" >&2
    if [[ -n "$project" && -n "$(compose ps -aq dss 2>/dev/null)" ]]; then
        echo "[smoke] Last container logs:" >&2
        compose logs --no-log-prefix --tail 40 dss >&2 || true
    fi
    exit 1
}

# remove_project: removes the current Compose project with its volumes, and the
# guard container and volume.
remove_project() {
    docker rm -f "${project}-guard" >/dev/null 2>&1 || true
    docker volume rm "${project}_guard" >/dev/null 2>&1 || true
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}

cleanup() {
    if [[ -z "$project" ]]; then
        return
    fi
    if [[ "$keep" == true ]]; then
        log "Keeping Compose project $project and volume ${project}_guard"
    else
        remove_project
    fi
}
trap cleanup EXIT

# expect_refusal NAME PATTERN DOCKER_RUN_ARGS...: runs the image's start command
# on the guard volume with DOCKER_RUN_ARGS, and checks that it exits with an
# error matching PATTERN. The timeout covers a start that wrongly goes ahead.
expect_refusal() {
    local name=$1 pattern=$2 output
    shift 2
    if output=$(timeout 300 docker run --rm --name "${project}-guard" \
            -v "${project}_guard:/home/dataiku/dss" "$@" "$image" 2>&1); then
        fail "$name: the container started instead of refusing"
    fi
    if ! grep -q -- "$pattern" <<<"$output"; then
        echo "$output" >&2
        fail "$name: expected an error matching: $pattern"
    fi
    log "OK: refuses $name"
}

# set_data_version VERSION: makes the guard volume look like a data directory
# last used by DSS VERSION.
set_data_version() {
    docker run --rm -v "${project}_guard:/home/dataiku/dss" "$image" \
        bash -c 'echo "{\"product_version\": \"$1\"}" >"$DSS_DATADIR/dss-version.json"' _ "$1"
}

wait_healthy() {
    local id state=unknown deadline=$((SECONDS + SMOKE_TIMEOUT))
    id=$(compose ps -aq dss)
    while (( SECONDS < deadline )); do
        state=$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$id")
        case $state in
            "running healthy") return 0 ;;
            "running "*) sleep 10 ;;
            *) fail "container is $state" ;;
        esac
    done
    fail "DSS not healthy after ${SMOKE_TIMEOUT}s (state: $state)"
}

# in_container: runs the bash script read from stdin in the DSS container.
in_container() { docker exec -i "$(compose ps -q dss)" bash -s; }

# count_logs PATTERN: number of container log lines matching PATTERN.
count_logs() { compose logs --no-log-prefix dss | grep -c -- "$1" || true; }

check_logs() {
    local errors
    errors=$(compose logs --no-log-prefix dss \
        | grep -E '^\[-\]|command not found|start-dss\.sh: line [0-9]+|dss-init\.sh: line [0-9]+|Permission denied' || true)
    if [[ -n "$errors" ]]; then
        echo "$errors" >&2
        fail "errors in the startup logs"
    fi
    log "OK: no errors in the startup logs"
}

check_jdbc_drivers() {
    local result
    result=$(in_container <<'EOF'
set -eu
source=/home/dataiku/jdbc-drivers target=$DSS_DATADIR/lib/jdbc
jars=$(cd "$source" && find . -name '*.jar' -printf '%P\n' | sort)
for jar in $jars; do
    [[ -f "$target/$jar" && "$(sha256sum <"$source/$jar")" == "$(sha256sum <"$target/$jar")" ]] \
        || { echo "missing or different: lib/jdbc/$jar"; exit 1; }
done
if [[ -n "$jars" ]]; then
    [[ "$(cat "$target/.dss-bootstrap-drivers")" == "$jars" ]] || { echo "the manifest does not list the image's jars"; exit 1; }
else
    [[ ! -e "$target/.dss-bootstrap-drivers" ]] || { echo "a manifest is left with no jars in the image"; exit 1; }
fi
echo ${jars:-none}
EOF
    ) || fail "JDBC drivers: $result"
    log "OK: JDBC drivers in lib/jdbc: $result"
}

check_license() {
    local status
    if [[ ! -f license/license.json ]]; then
        (( $(count_logs 'DSS will run in its default free mode') > 0 )) \
            || fail "no license provided, but no free mode warning in the logs"
        log "OK: no license provided, free mode warning logged"
        return
    fi
    # Asks DSS itself, through its API, whether the installed license is valid.
    # Prints only the validity flags, never the license content.
    # No set -u: DSS's environment scripts use unset variables.
    status=$(in_container 2>&1 <<'EOF'
set -e
[[ "$(sha256sum <"$DSS_LICENSE_FILE")" == "$(sha256sum <"$DSS_DATADIR/config/license.json")" ]] \
    || { echo "config/license.json differs from the provided license"; exit 1; }
export DIP_HOME=$DSS_DATADIR DKU_LAMBDA_HOME=$DSS_DATADIR
source "$DIP_HOME/bin/env-default.sh"
source "$DKUINSTALLDIR/scripts/_startup.inc.sh"
bkdl_set_global_env; bkdl_set_py_env; bkdl_load_env_files
export PYTHONPATH="$DIP_HOME/lib/python:$DKUINSTALLDIR/python"
"$DKUPYTHONBIN" - <<'PY'
import os, dataikuapi
from dataiku.dsscli.auth import get_or_create_api_key
client = dataikuapi.DSSClient("http://127.0.0.1:%s" % os.environ["DKU_BACKEND_PORT"],
                              get_or_create_api_key(impersonate_user=""))
base = client.get_licensing_status().get("base") or {}
print("hasLicense=%s valid=%s expired=%s" % (base.get("hasLicense"), base.get("valid"), base.get("expired")))
PY
EOF
    ) || fail "license check: $status"
    status=$(tail -n 1 <<<"$status")
    [[ "$status" == "hasLicense=True valid=True expired=False" ]] || fail "DSS does not accept the license: $status"
    log "OK: license installed and accepted by DSS ($status)"
}

smoke_test() {
    local spec=$1 version installs
    if [[ -n "$spec" ]]; then
        version=${spec%%@*}
        export DSS_VERSION=$version DSS_IMAGE_DIGEST=
        if [[ "$spec" == *@* ]]; then
            DSS_IMAGE_DIGEST=${spec#*@}
        fi
    else
        unset DSS_VERSION DSS_IMAGE_DIGEST
    fi
    export DSS_PORT=$SMOKE_PORT DSS_ALLOW_UPGRADE=

    project=dss-smoke
    image=$(compose config --images)
    version=${image##*:}
    project=dss-smoke-${version//./-}
    log "=== DSS $version (${spec:-as resolved by docker-compose.yml}), Compose project $project"
    remove_project

    log "Building $image"
    compose build --quiet dss || fail "build failed"

    # The start command must refuse these before changing anything.
    docker volume create "${project}_guard" >/dev/null
    expect_refusal "a license that is not JSON" "is not valid JSON" \
        -e DSS_LICENSE_FILE=/home/dataiku/run.sh
    expect_refusal "a license path that is a directory" "is not a readable file" \
        -e DSS_LICENSE_FILE=/home/dataiku
    set_data_version 999.0.0
    expect_refusal "a data directory from a newer DSS" "DSS cannot downgrade a data directory"
    set_data_version 1.0.0
    expect_refusal "an upgrade without DSS_ALLOW_UPGRADE" "set DSS_ALLOW_UPGRADE=$version"
    expect_refusal "an upgrade with no backup folder mounted" "is not a writable directory" \
        -e "DSS_ALLOW_UPGRADE=$version"

    log "Starting DSS on a fresh volume, port $SMOKE_PORT"
    compose --progress quiet up -d --no-build dss
    wait_healthy
    log "OK: healthy after a fresh install"
    check_logs
    check_jdbc_drivers
    check_license

    log "Restarting"
    installs=$(count_logs '^\[+\] Installing JDBC driver')
    compose --progress quiet restart dss
    wait_healthy
    log "OK: healthy after a restart"
    check_logs
    (( $(count_logs '^\[+\] Installing JDBC driver') == installs )) || fail "JDBC drivers were installed again on restart"
    if [[ -f license/license.json ]]; then
        (( $(count_logs '^\[+\] DSS license is up to date') == 1 )) || fail "the license was not reported up to date on restart"
    fi
    log "OK: nothing installed again on restart"
    check_jdbc_drivers
    check_license

    cleanup
    project=
    log "PASS: DSS $version"
}

if (( $# == 0 )); then
    set -- ""
fi
for spec in "$@"; do
    smoke_test "$spec"
done
log "All smoke tests passed"
