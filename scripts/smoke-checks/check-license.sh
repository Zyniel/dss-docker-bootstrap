#!/bin/bash
# Runs inside the DSS container, started by smoke-test.sh.
#
# Checks that DSS uses the license provided in license/license.json, then asks
# DSS itself whether it accepts that license. The last line printed is the
# answer, from license_status.py.
#
# No "set -u" here: DSS's own environment scripts, loaded below, use variables
# that may be unset, and -u would stop them with an error.
set -e

provided=$DSS_LICENSE_FILE
installed=$DSS_DATADIR/config/license.json

# start-dss.sh copies the provided license into the data directory. Compare
# checksums of the two files: the same checksum means the same content.
if [[ "$(sha256sum <"$provided")" != "$(sha256sum <"$installed")" ]]; then
    echo "config/license.json differs from the provided license"
    exit 1
fi

# Set up the same environment as DSS's own command line tool, bin/dsscli, so
# that Python finds DSS's libraries and the port of the DSS backend.
export DIP_HOME=$DSS_DATADIR
export DKU_LAMBDA_HOME=$DSS_DATADIR
# shellcheck source=/dev/null
source "$DIP_HOME/bin/env-default.sh"
# shellcheck source=/dev/null
source "$DKUINSTALLDIR/scripts/_startup.inc.sh"
bkdl_set_global_env
bkdl_set_py_env
bkdl_load_env_files
export PYTHONPATH="$DIP_HOME/lib/python:$DKUINSTALLDIR/python"

# $(dirname "$0") is the folder this script is in, where license_status.py is.
"$DKUPYTHONBIN" "$(dirname "$0")/license_status.py"
