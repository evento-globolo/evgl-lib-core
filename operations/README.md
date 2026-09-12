# Capability profiles

- `contracts`: immutable JSON/SQL/provenance without a database connection.
- `read`: opaque actor-and-tenant scoped read context for the
  `evgl__web_ro` role. No raw SeaORM handle is exported.
- `write`: opaque write context for the `evgl__api_rw` role. Product
  authorization and transaction composition remain API responsibilities.
- `migrator`: bounded DPM diff/verify/bootstrap planning. Apply is deliberately
  not representable.

Named product reads and writes must be added here before a deployable consumes
the corresponding capability. Table names are never treated as public API
contracts.
