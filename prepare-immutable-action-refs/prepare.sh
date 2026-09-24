#!/usr/bin/env bash
# Prototype pre-processing step: uses CodeQL itself to discover every non-SHA-pinned
# `owner/repo@ref` used by GitHub Actions workflows/actions in the scanned repository, checks
# each `(owner/repo, ref)` pair against GitHub's Immutable Releases feature via the REST API's
# `GET /repos/{owner}/{repo}/releases/tags/{tag}` endpoint (which exposes an `immutable` boolean),
# and emits a CodeQL data extension file (`immutableActionRefsDataModel`) that the
# `actions/unpinned-tag` query can consume to avoid flagging refs that are already immutable.
#
# Requires: codeql (CLI, on PATH or via CODEQL_PATH), gh, jq.
set -euo pipefail

CODEQL="${CODEQL_PATH:-codeql}"
DB_PATH="${1:?Usage: prepare.sh <actions-database-path> <output-model-pack.yml>}"
OUTPUT_PATH="${2:?Usage: prepare.sh <actions-database-path> <output-model-pack.yml>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Running CodeQL query to list candidate action refs..."
"$CODEQL" query run \
  "$SCRIPT_DIR/list-unpinned-action-refs.ql" \
  --database="$DB_PATH" \
  --output="$WORKDIR/refs.bqrs"

"$CODEQL" bqrs decode --format=json --output="$WORKDIR/refs.json" "$WORKDIR/refs.bqrs"

# Deduplicated `action,ref` pairs (tab-separated, no quoting) whose ref looks like a release
# version (vX / vX.Y / vX.Y.Z, optional leading "v"); branch names, "latest", "main", etc. can
# never correspond to a GitHub Release, so there's no point calling the API for those.
jq -r '
  .["#select"].tuples[]
  | [.[0], .[1]]
  | @tsv
' "$WORKDIR/refs.json" \
  | sort -u \
  | awk -F'\t' '$2 ~ /^v?[0-9]+(\.[0-9]+){0,2}$/' \
  > "$WORKDIR/candidates.tsv"

: > "$WORKDIR/immutable.tsv"
while IFS=$'\t' read -r action ref; do
  owner="${action%%/*}"
  name="${action#*/}"

  echo "Checking $owner/$name@$ref..." >&2
  # A 404 means there is no release for this tag (e.g. it's a moving major/minor tag like `v6`,
  # or a branch name that slipped through the version-like filter above); treat that, and any
  # other failure, as "not immutable" rather than aborting the whole run.
  immutable=$(gh api "repos/$owner/$name/releases/tags/$ref" --jq '.immutable // false' 2>/dev/null || echo "false")

  if [ "$immutable" = "true" ]; then
    printf '%s\t%s\n' "$action" "$ref" >> "$WORKDIR/immutable.tsv"
  fi
done < "$WORKDIR/candidates.tsv"

echo "Writing data extension to $OUTPUT_PATH..."
{
  echo "extensions:"
  echo "  - addsTo:"
  echo "      pack: codeql/actions-all"
  echo "      extensible: immutableActionRefsDataModel"
  echo "    data:"
  while IFS=$'\t' read -r action ref; do
    echo "      - [\"$action\", \"$ref\"]"
  done < "$WORKDIR/immutable.tsv"
} > "$OUTPUT_PATH"

echo "Done. $(wc -l < "$WORKDIR/immutable.tsv") immutable ref(s) found out of $(wc -l < "$WORKDIR/candidates.tsv") candidate(s)."
