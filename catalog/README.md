# catalog

`catalog.json` is the generated HCS-0001 catalog manifest (HCS v0.1.0-draft.7,
`"hcsVersion": "0.1"`) of the factory's own distributable parts. It has one entry,
`dev.fullfran.gentle-factory.pipeline`: the pipeline embedded in the binary
(`pipeline/`, `//go:embed factory.json *.md *.sh`), packaged as a deterministic
ustar archive compressed with gzip. Never edit `catalog.json` by hand.

- `source.json` (hand-written): the catalog `id` and `version`; the entry takes the same version.
- `contentHash` and `size`: sha256 and length of the gzip bytes.
- `contentId`: sha256 of the uncompressed tar stream.
- `contributions`: one per embedded file (`x-gentle-factory-spec`, `-prompt` or `-node`).

## Commands

```bash
go run ./cmd/catalog build [--archive FILE]   # rewrite catalog.json (and write the package bytes to FILE)
go run ./cmd/catalog check                    # exit 1 when catalog.json does not match the embedded pipeline (contentId)
```

Run `build` after any change to an embedded file under `pipeline/`, including a new
`*.md` or `*.sh` file. `check` rebuilds in memory, compares it with `catalog.json` and
`source.json`, enforces the HCS-0001 rules on the document, and prints one line per
problem. Both commands find the repository root by walking up to `go.mod`;
`--root DIR` overrides it. The file set always comes from the pipeline compiled into
the command, so to test a change to `pipeline/` run the command from that tree.

## Toolchain limit

`contentHash` and `size` depend on the gzip output of the Go standard library. That
output is stable for a given Go toolchain but differs across Go versions (the catalog
built in the factory box and a rebuild on a laptop with another Go give different gzip
bytes). `contentId`, the sha256 of the uncompressed tar, does not depend on compression,
so `check` treats it as the content identity: a different `contentId` fails; the same
`contentId` with a different `contentHash` or `size` prints a `WARN` line and exits 0.
Run `build` to refresh the gzip fields for your toolchain.

The HCS schemas are vendored in `../schemas/hcs/`; validating `catalog.json` against
them with a JSON Schema validator is a later slice.
