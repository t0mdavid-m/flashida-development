#!/usr/bin/env bash
# Archive specs whose frontmatter status is "implemented" or "superseded".
# Invoked as a Stop hook — exit 0 even if nothing to do.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SPEC_DIR="${REPO_ROOT}/docs/superpowers/specs"
ARCHIVE_DIR="${SPEC_DIR}/archive"

# Nothing to do if the spec dir doesn't exist (e.g. fresh clone).
[ -d "${SPEC_DIR}" ] || exit 0

mkdir -p "${ARCHIVE_DIR}"

shopt -s nullglob
for spec in "${SPEC_DIR}"/*.md; do
  # Extract the frontmatter (between first two '---' lines) and look for status:.
  status=$(awk '
    BEGIN { in_fm = 0; count = 0 }
    /^---[[:space:]]*$/ {
      count++
      if (count == 1) { in_fm = 1; next }
      if (count == 2) { in_fm = 0; exit }
    }
    in_fm && /^status:/ {
      sub(/^status:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")    # strip inline comment
      sub(/[[:space:]]+$/, "")       # trim trailing whitespace
      gsub(/^[\x22\x27]|[\x22\x27]$/, "")  # strip surrounding quotes
      print
      exit
    }
  ' "${spec}")

  case "${status}" in
    implemented|superseded)
      mv "${spec}" "${ARCHIVE_DIR}/"
      echo "archived: $(basename "${spec}") (status=${status})" >&2
      ;;
  esac
done

exit 0
