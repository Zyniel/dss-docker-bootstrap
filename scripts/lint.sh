#!/bin/bash
# Lints the shell scripts with ShellCheck and image/Dockerfile with Hadolint.
#
# Runs on your machine, from Git Bash on Windows. Both linters run from their
# official images at pinned versions, so only Docker is needed.
#
# Usage: scripts/lint.sh
set -euo pipefail # stop at the first failing command, unset variable or failed pipe

SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0
HADOLINT_IMAGE=hadolint/hadolint:v2.14.0

# Git Bash on Windows rewrites arguments that look like Unix paths into Windows
# paths. Docker needs them unchanged.
export MSYS_NO_PATHCONV=1

# Work from the project folder, the parent of scripts/. Docker needs the
# Windows form of its path, which "pwd -W" prints in Git Bash; elsewhere, pwd.
cd "$(dirname "$0")/.."
project_dir=$(pwd -W 2>/dev/null || pwd)

# All the shell scripts in the project, as paths relative to it. mapfile reads
# lines into an array, and "< <(...)" gives it the output of the commands in
# the parentheses.
mapfile -t scripts < <(find . -name '*.sh' -not -path './.git/*' -printf '%P\n' | sort)

# Run both linters, and remember whether either one failed: "|| status=1"
# keeps set -e from stopping the script at the first failure.
status=0
echo "[lint] ShellCheck: ${scripts[*]}"
docker run --rm -v "$project_dir:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" "${scripts[@]}" || status=1
echo "[lint] Hadolint: image/Dockerfile"
docker run --rm -i "$HADOLINT_IMAGE" hadolint --no-color - <image/Dockerfile || status=1

if [[ $status -eq 0 ]]; then
    echo "[lint] Passed"
else
    echo "[lint] FAIL: see the findings above" >&2
fi
exit "$status"
