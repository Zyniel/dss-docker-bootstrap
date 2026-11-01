#!/bin/bash
#
# Smoke test for the DSS image: builds it, starts it and checks that it works.
#
# For each DSS version given, the test:
#   1. builds the image with Docker Compose;
#   2. checks that the container refuses to start when something is wrong (a
#      bad license, a data directory from another DSS version), and that it
#      refuses before changing anything;
#   3. starts DSS on a new, empty volume and waits until it is healthy;
#   4. checks the startup logs, the JDBC drivers and the license;
#   5. restarts DSS and checks that nothing is installed a second time.
#
# Each version runs in its own throwaway Compose project, named
# dss-smoke-<version>, deleted at the end with its volumes unless --keep is
# given. If license/license.json exists, it is used, and DSS must accept it.
# The checks that run inside the DSS container are in scripts/smoke-checks/.
#
# Usage:
#   scripts/smoke-test.sh                   test the version docker-compose.yml
#                                           uses, from .env or its defaults
#   scripts/smoke-test.sh 13.4.4 15.2.0     test these dataiku/dss tags
#   scripts/smoke-test.sh 15.2.0@sha256:... test a tag pinned to a digest
#   scripts/smoke-test.sh --keep 13.4.4     keep the test project afterwards
#
# Optional environment variables:
#   SMOKE_PORT     host port for DSS during the test (default 10100)
#   SMOKE_TIMEOUT  seconds to wait for DSS to be healthy (default 1200)

# Stop at the first error:
#   -e           exit as soon as a command fails
#   -u           treat the use of an unset variable as an error
#   -o pipefail  a pipeline (a | b) fails if any command in it fails
set -euo pipefail

# Git Bash on Windows rewrites arguments that look like Unix paths, such as
# /home/dataiku, into Windows paths. Docker needs them unchanged.
export MSYS_NO_PATHCONV=1

# Work from the project folder, the parent of scripts/, wherever the script is
# started from, so that docker-compose.yml and license/ are found.
cd "$(dirname "$0")/.."

# ${NAME:-default} is the value of NAME, or "default" when NAME is unset or empty.
SMOKE_PORT=${SMOKE_PORT:-10100}
SMOKE_TIMEOUT=${SMOKE_TIMEOUT:-1200}

# Set by smoke_test for each version, and used by the functions below.
project=""  # Compose project name, for example dss-smoke-13-4-4
image=""    # image name, for example dss-smoke-13-4-4-dss:13.4.4
keep=false  # true when --keep is given

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# log MESSAGE: prints a progress message.
log() {
    echo "[smoke] $*"
}

# compose ARGUMENTS...: runs "docker compose" on the current test project.
# "$@" passes on all the arguments the function was given, unchanged.
compose() {
    docker compose -p "$project" "$@"
}

# fail MESSAGE: prints the error and the end of the DSS logs, then stops the
# script. ">&2" writes to the error output instead of the normal output.
fail() {
    echo "[smoke] FAIL: $*" >&2
    if [[ -n "$project" ]]; then
        echo "[smoke] Last container logs:" >&2
        compose logs --no-log-prefix --tail 40 dss >&2 || true
    fi
    exit 1
}

# remove_project: deletes the test project's containers, volumes and image.
# ">/dev/null 2>&1" hides all output, and "|| true" ignores errors, for example
# when there is nothing to delete. The braces in ${project}_guard are needed:
# without them, bash would look for a variable named project_guard.
remove_project() {
    docker rm -f "$project-guard" >/dev/null 2>&1 || true
    docker volume rm "${project}_guard" >/dev/null 2>&1 || true
    compose down --volumes --remove-orphans --rmi all >/dev/null 2>&1 || true
}

# cleanup: deletes the test project, unless --keep was given. "trap" makes it
# run whenever the script exits, whether the tests passed or failed.
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

# count_logs TEXT: prints how many lines of the DSS logs contain TEXT.
# grep -c counts the matching lines; it reports an error when it finds none,
# hence "|| true".
count_logs() {
    compose logs --no-log-prefix dss | grep -c -F "$1" || true
}

# wait_healthy: waits until Docker reports the DSS container as "healthy" (see
# HEALTHCHECK in the Dockerfile). Fails if the container stops running, or
# after SMOKE_TIMEOUT seconds.
wait_healthy() {
    local container
    local status
    local health=unknown
    # SECONDS is a bash variable: the number of seconds since the script started.
    local deadline=$((SECONDS + SMOKE_TIMEOUT))

    container=$(compose ps -aq dss)
    while [[ $SECONDS -lt $deadline ]]; do
        status=$(docker inspect -f '{{.State.Status}}' "$container")
        health=$(docker inspect -f '{{.State.Health.Status}}' "$container")
        if [[ "$status" != "running" ]]; then
            fail "the container is $status instead of running"
        fi
        if [[ "$health" == "healthy" ]]; then
            return 0
        fi
        # Still "starting" (or "unhealthy"): check again in 10 seconds.
        sleep 10
    done
    fail "DSS is not healthy after $SMOKE_TIMEOUT seconds (health: $health)"
}

# run_in_container SCRIPT: runs one of the scripts in scripts/smoke-checks/
# inside the DSS container, where DSS's files and tools are, and prints its
# output. The folder is copied into the container's /tmp first.
run_in_container() {
    local container
    container=$(compose ps -q dss)
    docker cp scripts/smoke-checks "$container:/tmp/" >/dev/null
    docker exec "$container" bash "/tmp/smoke-checks/$1"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# expect_refusal DESCRIPTION EXPECTED_ERROR [DOCKER_RUN_OPTIONS...]
#   Starts the image on the guard volume, with the extra "docker run" options
#   given, and checks that its start command exits with an error containing
#   EXPECTED_ERROR. "timeout 300" stops the test if DSS starts after all.
expect_refusal() {
    local description=$1
    local expected_error=$2
    local output
    # Drop the first two arguments: "$@" is now the docker run options.
    shift 2

    # $(...) captures what the command prints; 2>&1 includes its errors.
    if output=$(timeout 300 docker run --rm --name "$project-guard" \
            -v "${project}_guard:/home/dataiku/dss" "$@" "$image" 2>&1); then
        fail "$description: the container started instead of refusing"
    fi
    # "<<<" passes the text in $output to grep as its input.
    if ! grep -q -F "$expected_error" <<<"$output"; then
        echo "$output" >&2
        fail "$description: expected an error containing: $expected_error"
    fi
    log "OK: refuses $description"
}

# set_data_version VERSION: writes a dss-version.json file into the guard
# volume, so that it looks like a data directory last used by DSS VERSION.
# The command between single quotes runs in the container, where the variables
# FAKE_VERSION (given with -e) and DSS_DATADIR are set.
set_data_version() {
    docker run --rm -e "FAKE_VERSION=$1" -v "${project}_guard:/home/dataiku/dss" "$image" \
        bash -c 'echo "{\"product_version\": \"$FAKE_VERSION\"}" >"$DSS_DATADIR/dss-version.json"'
}

# check_refusals VERSION: checks that start-dss.sh stops, before changing
# anything, when it is given something it cannot use. The cases run on a
# separate "guard" volume, not on the one DSS is then tested on.
check_refusals() {
    local version=$1
    docker volume create "${project}_guard" >/dev/null

    # A license that is not JSON: run.sh is a file that exists in the image.
    expect_refusal "a license that is not JSON" "is not valid JSON" \
        -e DSS_LICENSE_FILE=/home/dataiku/run.sh
    # A license path that is a folder.
    expect_refusal "a license path that is a directory" "is not a readable file" \
        -e DSS_LICENSE_FILE=/home/dataiku

    # A data directory from a newer DSS, which DSS cannot downgrade.
    set_data_version 999.0.0
    expect_refusal "a data directory from a newer DSS" "DSS cannot downgrade a data directory"

    # A data directory from an older DSS: upgrading it needs DSS_ALLOW_UPGRADE,
    # and a backup folder, which a plain "docker run" does not mount.
    set_data_version 1.0.0
    expect_refusal "an upgrade without DSS_ALLOW_UPGRADE" "set DSS_ALLOW_UPGRADE=$version"
    expect_refusal "an upgrade with no backup folder mounted" "is not a writable directory" \
        -e "DSS_ALLOW_UPGRADE=$version"
}

# check_logs: fails if the DSS logs contain errors from the startup scripts:
# their own "[-]" messages, or the shell errors that bugs cause.
check_logs() {
    local errors
    errors=$(compose logs --no-log-prefix dss | grep -E \
        -e '^\[-\]' \
        -e 'command not found' \
        -e 'start-dss\.sh: line [0-9]+' \
        -e 'dss-init\.sh: line [0-9]+' \
        -e 'Permission denied' || true)
    if [[ -n "$errors" ]]; then
        echo "$errors" >&2
        fail "errors in the startup logs"
    fi
    log "OK: no errors in the startup logs"
}

# check_jdbc_drivers: checks the JDBC drivers in the data directory (see
# scripts/smoke-checks/check-jdbc-drivers.sh).
check_jdbc_drivers() {
    local result
    if ! result=$(run_in_container check-jdbc-drivers.sh); then
        fail "JDBC drivers: $result"
    fi
    log "OK: JDBC drivers in lib/jdbc: $result"
}

# check_license: with a license, checks that DSS uses and accepts it (see
# scripts/smoke-checks/check-license.sh); without one, checks that the free
# mode warning was logged.
check_license() {
    local result
    if [[ ! -f license/license.json ]]; then
        if [[ $(count_logs 'DSS will run in its default free mode') -eq 0 ]]; then
            fail "no license provided, but no free mode warning in the logs"
        fi
        log "OK: no license provided, free mode warning logged"
        return
    fi

    if ! result=$(run_in_container check-license.sh 2>&1); then
        fail "license check: $result"
    fi
    # DSS may print warnings first: the answer is on the last line.
    result=$(echo "$result" | tail -n 1)
    if [[ "$result" != "hasLicense=True valid=True expired=False" ]]; then
        fail "DSS does not accept the license: $result"
    fi
    log "OK: license installed and accepted by DSS ($result)"
}

# check_restart: restarts DSS and checks that start-dss.sh found everything
# already in place. The container keeps the logs of both starts, so a second
# installation would add lines to them.
check_restart() {
    local installs_before
    local installs_after

    installs_before=$(count_logs '[+] Installing JDBC driver')
    log "Restarting"
    compose --progress quiet restart dss
    wait_healthy
    log "OK: healthy after a restart"
    check_logs

    installs_after=$(count_logs '[+] Installing JDBC driver')
    if [[ $installs_after -ne $installs_before ]]; then
        fail "JDBC drivers were installed again on restart"
    fi
    if [[ -f license/license.json && $(count_logs '[+] DSS license is up to date') -ne 1 ]]; then
        fail "the license was not reported up to date on restart"
    fi
    log "OK: nothing installed again on restart"
}

# ---------------------------------------------------------------------------
# Test of one version
# ---------------------------------------------------------------------------

# smoke_test SPEC: runs all the steps for one version. SPEC is a VERSION, a
# VERSION@DIGEST, or empty for the version docker-compose.yml uses.
smoke_test() {
    local spec=$1
    local version

    # Choose what docker-compose.yml builds. Variables exported here take
    # precedence over the .env file.
    if [[ -z "$spec" ]]; then
        # Use .env or the defaults.
        unset DSS_VERSION DSS_IMAGE_DIGEST
    elif [[ "$spec" == *@* ]]; then
        # Split "15.2.0@sha256:04b1..." at the "@": ${spec%%@*} removes
        # everything from the "@" on, ${spec#*@} everything up to it.
        export DSS_VERSION=${spec%%@*}
        export DSS_IMAGE_DIGEST=${spec#*@}
    else
        # Build from the tag alone.
        export DSS_VERSION=$spec
        export DSS_IMAGE_DIGEST=""
    fi
    export DSS_PORT=$SMOKE_PORT
    export DSS_ALLOW_UPGRADE=""

    # Ask Compose which DSS version this gives: the tag of the image name, for
    # example 13.4.4 in dss-smoke-dss:13.4.4. Compose needs some project name
    # even to read its configuration.
    project=dss-smoke
    image=$(compose config --images)
    version=${image##*:}  # everything after the last ":"
    # Name the test project after the version (project names cannot contain
    # dots), then get the image name for that project, which includes it, for
    # example dss-smoke-13-4-4-dss:13.4.4.
    project=dss-smoke-$(echo "$version" | tr '.' '-')
    image=$(compose config --images)
    log "=== DSS $version (${spec:-as resolved by docker-compose.yml}), Compose project $project"
    # In case an earlier run was interrupted.
    remove_project

    # 1. Build.
    log "Building $image"
    if ! compose build --quiet dss; then
        fail "build failed"
    fi

    # 2. Refusals.
    check_refusals "$version"

    # 3. Fresh start.
    log "Starting DSS on a fresh volume, port $SMOKE_PORT"
    compose --progress quiet up -d --no-build dss
    wait_healthy
    log "OK: healthy after a fresh install"

    # 4. Checks.
    check_logs
    check_jdbc_drivers
    check_license

    # 5. Restart, then the same checks again.
    check_restart
    check_jdbc_drivers
    check_license

    cleanup
    # Nothing left for cleanup to remove when the script exits.
    project=""
    log "PASS: DSS $version"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# ${1:-} is the first argument, or empty when there is none (with set -u,
# a plain $1 would be an error then).
if [[ "${1:-}" == "--keep" ]]; then
    keep=true
    # Remove --keep from the arguments.
    shift
fi

# $# is the number of arguments left.
if [[ $# -eq 0 ]]; then
    smoke_test ""
else
    for spec in "$@"; do
        smoke_test "$spec"
    done
fi
log "All smoke tests passed"
