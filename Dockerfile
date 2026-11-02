# Custom Dataiku DSS image: the official dataiku/dss image plus a startup
# wrapper that installs optional JDBC drivers (Oracle, Trino) and an optional
# license file into the DSS data directory before DSS starts. See README.md.

# The base image: a dataiku/dss version tag, optionally pinned to a digest,
# for example dataiku/dss:15.2.0 or dataiku/dss:15.2.0@sha256:04b18e41...
# Each instance's compose.yaml sets it. With a digest, Docker uses the digest
# and ignores the tag, so the check below makes sure the tag matches the DSS
# version actually in the image.
ARG DSS_BASE_IMAGE=dataiku/dss:13.4.4
FROM ${DSS_BASE_IMAGE}

# Inherited from the base image and relied on below:
#   USER dataiku (uid 1000), WORKDIR /home/dataiku
#   ENV DSS_VERSION, DSS_DATADIR=/home/dataiku/dss, DSS_PORT=10000
#   /home/dataiku/run.sh, the upstream startup script and default CMD

# Check that the tag in DSS_BASE_IMAGE is the DSS version the base image
# contains (its own DSS_VERSION): remove the "@digest" part, then keep what
# follows the last ":".
ARG DSS_BASE_IMAGE
RUN set -eu;     reference=${DSS_BASE_IMAGE%@*};     tag=${reference##*:};     if [ "$tag" != "$DSS_VERSION" ]; then         echo "DSS_BASE_IMAGE is $DSS_BASE_IMAGE, but the image contains DSS $DSS_VERSION: use a dataiku/dss version tag, and the digest of that tag" >&2;         exit 1;     fi

# Where start-dss.sh looks for the license inside the container.
# compose.base.yaml mounts the license folder here read-only. A missing file is
# not an error: DSS then runs in its default free mode.
ENV DSS_LICENSE_FILE=/home/dataiku/license/license.json

# Split upstream run.sh into "initialize" and "start".
#
# run.sh prepares the data directory in one of three ways:
#   - empty: run the DSS installer, then add R integration and graphics export
#   - created by another DSS version: upgrade it (start-dss.sh refuses to
#     start before that can happen)
#   - otherwise: leave it as is
# and its last line starts DSS straight away:
#   exec "$DSS_DATADIR"/bin/dss run
#
# That leaves no point where files (JDBC drivers, license) can be copied into
# the data directory after it exists but before DSS reads it. So dss-init.sh is
# generated as run.sh without that last line: start-dss.sh runs it, installs the
# drivers and the license, then starts DSS itself. run.sh is only read here, at
# build time; it is never executed by this image.
#
# The line is matched literally: single quotes keep $DSS_DATADIR unexpanded,
# -F disables regex matching and -x requires a whole-line match. If a future
# base image words it differently, the build fails here. Otherwise dss-init.sh
# would still start DSS, before the drivers and the license are installed.
# hadolint ignore=SC2016
RUN set -eu; \
    start_line='exec "$DSS_DATADIR"/bin/dss run'; \
    if ! grep -Fqx "$start_line" /home/dataiku/run.sh; then \
        echo "/home/dataiku/run.sh does not contain the expected line: $start_line" >&2; \
        exit 1; \
    fi; \
    grep -Fvx "$start_line" /home/dataiku/run.sh >/home/dataiku/dss-init.sh; \
    chmod 755 /home/dataiku/dss-init.sh

# Optional JDBC drivers. They cannot be put in the data directory here, since
# the installer needs it empty and the dss-data volume is mounted over it at
# runtime. So they are downloaded into /home/dataiku/jdbc-drivers, and
# start-dss.sh copies them to $DSS_DATADIR/lib/jdbc before DSS starts.
#
# Each instance's compose.yaml can set these versions. An empty version skips
# that driver. The RUN below sees both ARGs as environment variables, which is
# how the script reads them.
ARG ORACLE_JDBC_VERSION=21.24.0.0
ARG TRINO_JDBC_VERSION=484
COPY download-jdbc-drivers.sh /tmp/download-jdbc-drivers.sh
RUN bash /tmp/download-jdbc-drivers.sh /home/dataiku/jdbc-drivers

# Startup wrapper: runs dss-init.sh, installs the JDBC drivers and the license,
# then execs DSS.
COPY --chown=dataiku:dataiku start-dss.sh /home/dataiku/start-dss.sh

# Healthy once the DSS backend answers. /dip/api/ping is served by the backend
# itself, so the check fails while DSS is still being installed or started, and
# when the backend is down. A fresh install can take several minutes, hence the
# long start period.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --start-interval=10s --retries=3 \
    CMD curl -fsS -o /dev/null "http://127.0.0.1:$DSS_PORT/dip/api/ping" || exit 1

# Replaces the upstream CMD, which was /home/dataiku/run.sh. run.sh stays in the
# image, unchanged, but nothing calls it.
CMD ["/bin/bash", "/home/dataiku/start-dss.sh"]
