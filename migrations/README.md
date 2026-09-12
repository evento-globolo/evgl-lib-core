# Migration inputs

The files in `declarative/` are the reviewed inputs used to materialize
`contracts/database/desired.sql`. Their original repository, commit, path,
and SHA-256 digest are pinned in `contracts/database/sources.json`.

Run:

```bash
node tools/materialize-desired.mjs
node tools/materialize-desired.mjs --check
dpm diff --source contracts/database/desired.sql --target "$TARGET_DATABASE_URL" --shadow "$SHADOW_DATABASE_URL"
dpm verify --source contracts/database/desired.sql --target "$TARGET_DATABASE_URL" --shadow "$SHADOW_DATABASE_URL"
```

The Rust API intentionally has no `apply` operation. Production application
belongs to a serialized, reviewed one-shot migrator job with the
`evgl__migrator` role and a Fiducia lease/fencing token. Web, API, and
worker processes must never run DDL during startup.
