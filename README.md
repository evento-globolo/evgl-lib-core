# evgl-lib-core

Canonical Evento Globolo persistence contracts, ORM-generation inventory, opaque
database capability profiles, and declarative PostgreSQL/CockroachDB migration
planning.

This repository is the `DEN-3321` data-plane authority. Public HTTP/event
contracts remain in [evento-globolo/evgl-interfaces](https://github.com/evento-globolo/evgl-interfaces);
the mapping into persistence is explicit under
`contracts/mappings/interfaces-to-persistence/`.

## What is implemented

- reviewed SQL inputs with immutable repository, commit, path, and SHA-256 pins;
- deterministic `contracts/database/desired.sql` materialization;
- Draft 2020-12 persistence inventory schema with table/function drift checks;
- generated provenance containing source, schema, and desired-SQL digests;
- separate Cargo profiles for contracts, bounded reads, API-owned writes, and
  migrator planning;
- opaque SeaORM contexts that never export a raw connection;
- a bounded, secret-redacting DPM process adapter for `diff`, `verify`, and
  `bootstrap` only;
- CI for materialization drift, formatting, linting, and all-feature tests; and
- Zed dependencies on evento-globolo/evgl-interfaces,
  `ORESoftware/k8s-libs-and-shared-defs`, and
  `declarative-migrations/declarative-postgres-migrate.rs`.

## Migration lifecycle

```bash
node tools/materialize-desired.mjs --check

dpm diff \
  --source contracts/database/desired.sql \
  --target "$TARGET_DATABASE_URL" \
  --shadow "$SHADOW_DATABASE_URL"

dpm verify \
  --source contracts/database/desired.sql \
  --target "$TARGET_DATABASE_URL" \
  --shadow "$SHADOW_DATABASE_URL"
```

Applying a reviewed plan is intentionally outside the library API. Production
DDL belongs to a serialized one-shot job using `evgl__migrator`; normal
API, web, and worker startup must not migrate.

## Bootstrap boundary

The current JSON Schema is an exact table/function inventory over the preserved
SQL history. Column-level JSON mappings and checked-in generated SeaORM,
Drizzle, Prisma/TypeORM, Ent, and Drift output remain a semantic follow-up:
the generator versions and required output paths are pinned now, but the repo
does not fabricate column semantics that have not yet been reconciled against
a materialized catalog. Until that review lands, this package is a migration
foundation and must not be advertised as complete adapter parity.

MIT licensed.
