# Custom Dataiku DSS image: the official dataiku/dss image plus a startup
# wrapper that installs optional JDBC drivers (Oracle, Trino) and an optional
# license file into the DSS data directory before DSS starts. See README.md.

# Select the base image: DSS_VERSION is its tag, and DSS_IMAGE_DIGEST, when not
# empty, pins the exact image published under that tag, so a tag pushed again
# upstream cannot change the build. With a digest, Docker ignores the tag, so
# the digest must be the one of dataiku/dss:$DSS_VERSION; the check below fails
# the build otherwise. The default is the digest of dataiku/dss:13.4.4.
#
# The DSS_VERSION environment variable seen at runtime is set by the base image
# itself, so it always matches the DSS installed in it.
#
# DSS_BASE_IMAGE is derived from both; it is an ARG rather than written in FROM
# only because Hadolint cannot parse the ":+" expansion there.
ARG DSS_VERSION=13.4.4
ARG DSS_IMAGE_DIGEST=sha256:8bc5cd7512506a453e9ba9866786ff22937b3194dc70039539e5d04890b6a002
ARG DSS_BASE_IMAGE=dataiku/dss:${DSS_VERSION}${DSS_IMAGE_DIGEST:+@${DSS_IMAGE_DIGEST}}
FROM ${DSS_BASE_IMAGE}

# Inherited from the base image and relied on below:
#   USER dataiku (uid 1000), WORKDIR /home/dataiku
#   ENV DSS_VERSION, DSS_DATADIR=/home/dataiku/dss, DSS_PORT=10000
#   /home/dataiku/run.sh, the upstream startup script and default CMD
#   /home/dataiku/dataiku-dss-$DSS_VERSION, the DSS installation used by run.sh

# Check that the base image runs the requested DSS version. Declared again here,
# the DSS_VERSION build argument hides the base image's own DSS_VERSION in the
# RUN instructions below, so the installation directory is checked instead.
ARG DSS_VERSION
RUN set -eu; \
    if [ ! -d "/home/dataiku/dataiku-dss-$DSS_VERSION" ]; then \
        echo "The base image does not contain DSS $DSS_VERSION, only: $(echo /home/dataiku/dataiku-dss-*)" >&2; \
        echo "Set DSS_IMAGE_DIGEST to the digest of dataiku/dss:$DSS_VERSION, or to empty to use the tag alone" >&2; \
        exit 1; \
    fi

# Where start-dss.sh looks for the license inside the container.
# docker-compose.yml mounts ./license here read-only. A missing file is not an
# error: DSS then runs in its default free mode.
ENV DSS_LICENSE_FILE=/home/dataiku/license/license.json

# Where start-dss.sh saves a backup of the data directory before upgrading it.
# docker-compose.yml mounts ./backups here. Upgrades are refused when this is
# not a writable directory.
ENV DSS_BACKUP_DIR=/home/dataiku/backups

# Split upstream run.sh into "initialize" and "start".
#
# run.sh prepares the data directory in one of three ways:
#   - empty: run the DSS installer, then add R integration and graphics export
#   - created by another DSS version: upgrade it
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
# docker-compose.yml passes these versions from .env. An empty version skips
# that driver. Changing a version requires a rebuild. The RUN below sees both
# ARGs as environment variables, which is how the script reads them.
ARG ORACLE_JDBC_VERSION=21.24.0.0
ARG TRINO_JDBC_VERSION=484
COPY download-jdbc-drivers.sh /tmp/download-jdbc-drivers.sh
RUN bash /tmp/download-jdbc-drivers.sh /home/dataiku/jdbc-drivers

# Startup wrapper: runs dss-init.sh, installs the JDBC drivers and the license,
# then execs DSS.
COPY --chown=dataiku:dataiku start-dss.sh /home/dataiku/start-dss.sh

# Healthy once the DSS backend answers. /dip/api/ping is served by the backend
# itself, so the check fails while DSS is still being installed, upgraded or
# started, and when the backend is down. A fresh install or an upgrade with a
# large backup can take several minutes, hence the long start period.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --start-interval=10s --retries=3 \
    CMD curl -fsS -o /dev/null "http://127.0.0.1:$DSS_PORT/dip/api/ping" || exit 1

# Replaces the upstream CMD, which was /home/dataiku/run.sh. run.sh stays in the
# image, unchanged, but nothing calls it.
CMD ["/bin/bash", "/home/dataiku/start-dss.sh"]
