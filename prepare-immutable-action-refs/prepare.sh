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

# Deduplicated `action,ref` pairs (tab-separated, no quoting). Every distinct ref is a candidate:
# a GitHub Release can be published against a tag of any name (`stable`, `release-2024-01`, even
# `latest` or `main` if someone chose to name it that way), and that release can be immutable
# regardless of whether the tag name looks like a semantic version, so we don't filter by shape
# here -- the REST lookup below is the actual source of truth, and simply returns 404 for refs
# that turn out to be branches or have no matching release.
jq -r '
  .["#select"].tuples[]
  | [.[0], .[1]]
  | @tsv
' "$WORKDIR/refs.json" \
  | tr -d '\r' \
  | sort -u \
  > "$WORKDIR/candidates.tsv"

: > "$WORKDIR/immutable.tsv"
while IFS=$'\t' read -r action ref; do
  owner="${action%%/*}"
  name="${action#*/}"

  echo "Checking $owner/$name@$ref..." >&2
  # A 404 means there is no release for this tag (e.g. it's a branch name, or a moving
  # major/minor tag like `v6` that was never itself released); treat that, and any other
  # failure, as "not immutable" rather than aborting the whole run.
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
