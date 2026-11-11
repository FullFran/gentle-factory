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
go run ./cmd/catalog check                    # exit 1 when catalog.json does not match the embedded pipeline
```

Run `build` after any change to an embedded file under `pipeline/`, including a new
`*.md` or `*.sh` file. `check` rebuilds in memory, compares it with `catalog.json` and
`source.json`, enforces the HCS-0001 rules on the document, and prints one line per
problem. Both commands find the repository root by walking up to `go.mod`;
`--root DIR` overrides it. The file set always comes from the pipeline compiled into
the command, so to test a change to `pipeline/` run the command from that tree.

## Toolchain limit

`contentHash` and `size` depend on the gzip output of the Go standard library. That
output is stable for a given Go toolchain but is not guaranteed across Go versions, so
a toolchain upgrade can make `check` fail until `build` is run again. `contentId` does
not depend on compression.

The HCS schemas are vendored in `../schemas/hcs/`; validating `catalog.json` against
them with a JSON Schema validator is a later slice.
