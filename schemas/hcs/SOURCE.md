# Vendored HCS schemas

Copied byte for byte from FullFran/hcs at tag `v0.1.0-draft.7` (released 2026-11-11). Do not edit these files; replace them by vendoring a newer release.

| File | Path in the release | `$id` | sha256 |
|---|---|---|---|
| `common.schema.json` | `schemas/hcs-0000/common/v0.1/common.schema.json` | `urn:hcs:schema:hcs-0000:common:0.1` | `8864eb5ec941d375bc9a89bfb9770ff39aeb20c8ddbfdc0e2a53d80e93a620d2` |
| `capability.schema.json` | `schemas/hcs-0002/capability/v0.1/capability.schema.json` | `urn:hcs:schema:hcs-0002:capability:0.1` | `2efd66918f15185483436058d59cf287a62825af0531f74f0ccb313509d2e872` |
| `catalog-manifest.schema.json` | `schemas/hcs-0001/catalog-manifest/v0.1/catalog-manifest.schema.json` | `urn:hcs:schema:hcs-0001:catalog-manifest:0.1` | `39cd441b30081b5119192394254dddbabfd7749138792750569c19c7d23b6507` |

Fetched with:

```bash
gh api "repos/FullFran/hcs/contents/<path in the release>?ref=v0.1.0-draft.7" --jq .content | base64 -d > <file>
```
