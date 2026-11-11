#!/usr/bin/env bash
# Catalog tests: catalog/catalog.json describes exactly the embedded pipeline, the archive
# is reproducible, `check` catches drift, and the vendored HCS schemas match their pins.
# Needs go, jq, tar, gzip, sha256sum, cp and mktemp. Runs offline.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRATCH=$(mktemp -d /tmp/gentle-factory-catalog.XXXXXX)
trap 'rm -rf -- "$SCRATCH"' EXIT
passed=0
failed=0
ok() { printf 'PASS %s\n' "$1"; passed=$((passed + 1)); }
ko() { printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); }
expect() { # expect NAME CODE DIR CMD...: CMD run in DIR exits with CODE
  local name=$1 want=$2 dir=$3 got=0
  shift 3
  (cd "$dir" && "$@") >"$SCRATCH/out" 2>&1 || got=$?
  if [[ $got == "$want" ]]; then ok "$name"; else ko "$name (expected exit $want, got $got)"; sed 's/^/  /' "$SCRATCH/out"; fi
}
# A full copy of the repository: `go run` there compiles the copy's own pipeline/.
copy() { local d=$SCRATCH/$1; cp -a "$ROOT" "$d"; printf '%s\n' "$d"; }

# 1. The committed catalog is up to date.
expect check-committed-tree 0 "$ROOT" go run ./cmd/catalog check
CAT=$ROOT/catalog/catalog.json

# 2. Shape.
shape() { jq -e "$1" "$CAT" >/dev/null 2>&1; }
for q in '.hcsVersion == "0.1"' '.id == "dev.fullfran.gentle-factory"' '.entries | length == 1' \
  '.entries[0].mediaType == "application/vnd.oci.image.layer.v1.tar+gzip"' \
  '.entries[0].contentHash | test("^sha256:[a-f0-9]{64}$")' '.entries[0].contentId | test("^sha256:[a-f0-9]{64}$")' \
  '[.entries[0].contributions[].path | (contains("..") or startswith("/")) | not] | all' \
  '(.entries[0].contributions | length) >= 1'; do
  if shape "$q"; then ok "shape:$q"; else ko "shape:$q"; fi
done
want=$(cd "$ROOT/pipeline" && ls | grep -v '\.go$' | LC_ALL=C sort)
got=$(jq -r '.entries[0].contributions[].path' "$CAT" | LC_ALL=C sort)
if [[ $want == "$got" ]]; then ok contributions-equal-embedded-files; else ko "contributions-equal-embedded-files (want: $want; got: $got)"; fi

# 3. Archive bytes match the entry and are reproducible.
A=$(copy archive)
(cd "$A" && go run ./cmd/catalog build --archive "$SCRATCH/a.tgz" && go run ./cmd/catalog build --archive "$SCRATCH/b.tgz") >/dev/null 2>&1 \
  || ko archive-build
ACAT=$A/catalog/catalog.json
field() { jq -r ".entries[0].$1" "$ACAT"; }
if [[ "sha256:$(sha256sum "$SCRATCH/a.tgz" | cut -d' ' -f1)" == "$(field contentHash)" ]]; then ok archive-contentHash; else ko archive-contentHash; fi
if [[ $(wc -c <"$SCRATCH/a.tgz") == "$(field size)" ]]; then ok archive-size; else ko archive-size; fi
if [[ $(tar -tzf "$SCRATCH/a.tgz") == "$(jq -r '.entries[0].contributions[].path' "$ACAT" | LC_ALL=C sort)" ]]; then ok archive-listing; else ko archive-listing; fi
if [[ "sha256:$(gzip -dc "$SCRATCH/a.tgz" | sha256sum | cut -d' ' -f1)" == "$(field contentId)" ]]; then ok archive-contentId; else ko archive-contentId; fi
if cmp -s "$SCRATCH/a.tgz" "$SCRATCH/b.tgz"; then ok archive-reproducible; else ko archive-reproducible; fi
if cmp -s "$ACAT" "$CAT"; then ok build-matches-committed; else ko build-matches-committed; fi

# 4. Drift.
D=$(copy edit)
before=$(jq -r '.entries[0].contentHash' "$D/catalog/catalog.json")
printf 'drift\n' >>"$D/pipeline/plan.md"
expect drift:edited-file 1 "$D" go run ./cmd/catalog check
(cd "$D" && go run ./cmd/catalog build) >/dev/null 2>&1 || :
expect drift:edited-file-rebuilt 0 "$D" go run ./cmd/catalog check
if [[ $(jq -r '.entries[0].contentHash' "$D/catalog/catalog.json") != "$before" ]]; then ok drift:contentHash-changed; else ko drift:contentHash-changed; fi

D=$(copy add)
printf 'extra\n' >"$D/pipeline/extra.md"
expect drift:added-file 1 "$D" go run ./cmd/catalog check
(cd "$D" && go run ./cmd/catalog build >/dev/null 2>&1) || :
if jq -e '[.entries[0].contributions[].path] | index("extra.md")' "$D/catalog/catalog.json" >/dev/null; then ok drift:added-file-contributed; else ko drift:added-file-contributed; fi

D=$(copy size)
jq '.entries[0].size += 1' "$D/catalog/catalog.json" >"$SCRATCH/c.json" && cp "$SCRATCH/c.json" "$D/catalog/catalog.json"
expect drift:size 1 "$D" go run ./cmd/catalog check

D=$(copy source)
jq '.version = "0.1.1"' "$D/catalog/source.json" >"$SCRATCH/s.json" && cp "$SCRATCH/s.json" "$D/catalog/source.json"
expect drift:source-version 1 "$D" go run ./cmd/catalog check

# 5. Vendored schemas.
pin() { # pin FILE ID SHA256
  local f=$ROOT/schemas/hcs/$1
  if [[ $(sha256sum "$f" | cut -d' ' -f1) == "$3" ]]; then ok "schema-sha256:$1"; else ko "schema-sha256:$1"; fi
  if jq -e --arg id "$2" '."$id" == $id' "$f" >/dev/null; then ok "schema-id:$1"; else ko "schema-id:$1"; fi
}
pin common.schema.json urn:hcs:schema:hcs-0000:common:0.1 8864eb5ec941d375bc9a89bfb9770ff39aeb20c8ddbfdc0e2a53d80e93a620d2
pin capability.schema.json urn:hcs:schema:hcs-0002:capability:0.1 2efd66918f15185483436058d59cf287a62825af0531f74f0ccb313509d2e872
pin catalog-manifest.schema.json urn:hcs:schema:hcs-0001:catalog-manifest:0.1 39cd441b30081b5119192394254dddbabfd7749138792750569c19c7d23b6507

printf '%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
