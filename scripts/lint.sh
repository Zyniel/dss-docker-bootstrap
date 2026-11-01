#!/bin/bash
# Lints the shell scripts with ShellCheck and the Dockerfile with Hadolint. Both
# run from their official images at pinned versions, so only Docker is needed.
#
# Usage: scripts/lint.sh
set -euo pipefail

SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0
HADOLINT_IMAGE=hadolint/hadolint:v2.14.0

# Git Bash on Windows rewrites arguments that look like paths; Docker needs the
# Windows form of the project path (pwd -W) and container paths left as is.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
project_dir=$(pwd -W 2>/dev/null || pwd)

mapfile -t scripts < <(find . -name '*.sh' -not -path './.git/*' -not -path './backups/*' -printf '%P\n' | sort)

status=0
echo "ShellCheck: ${scripts[*]}"
docker run --rm -v "$project_dir:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" "${scripts[@]}" || status=1
echo "Hadolint: Dockerfile"
docker run --rm -i "$HADOLINT_IMAGE" hadolint --no-color - <Dockerfile || status=1

if (( status == 0 )); then
    echo "Lint passed"
fi
exit "$status"
