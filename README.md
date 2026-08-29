# evgl-lib-core

The single data boundary for `evento-globolo`: `evgl-mash-web` and `evgl-api` reach Postgres
through this crate and nothing else.

That is what makes avenue 1 of the [four-transport
contract](https://github.com/ORESoftware/ores-transport) safe. The web server
is allowed to skip the api server and read the database itself, and the
projection it renders is the same query builder the api server compiles — so
the two cannot drift apart.

## Reads only, twice over

| Guard | What it stops |
|-------|---------------|
| Cargo features | `read-only` is the default; `WriteContext` exists only under `read-write` and migrations only under `migrate`. A mutating call from a web server is a **compile error**. |
| Database role | The DSN in `EVGL_READONLY_DATABASE_URL` belongs to a role without `INSERT`, `UPDATE`, `DELETE` or DDL. |

A mistake has to defeat both. Depend on this crate from `evgl-mash-web` as:

```toml
evgl-lib-core = { git = "https://github.com/evento-globolo/evgl-lib-core.git", default-features = false, features = ["read-only"] }
```

and from `evgl-api` with `features = ["read-write"]`.

## TLS is not optional by accident

`sqlx` defaults to `sslmode=prefer`, which silently downgrades to plaintext
when the server declines TLS — a fallback that looks exactly like success.
This crate refuses a DSN that has not explicitly asked for `require`,
`verify-ca` or `verify-full`, unless the host is loopback. `TransportPolicy::
AllowPlaintext` is the deliberate opt-out for sidecar-terminated TLS.

Driver errors quote the DSN they failed on, so every error path here runs the
URL through `redact_dsn` first. A password does not reach a log.

## Raw connections do not escape

`ReadContext::connection` is `pub(crate)`. Consumers call named operations in
`reads`, which is what keeps one query from being written twice, differently,
in two services. `reads::server_time` is a placeholder with the right shape —
replace it with evgl's real projections.

## Migrations

Migrations live behind the `migrate` feature and belong to this crate and
[`declarative-migrations`](https://github.com/ORESoftware/declarative-migrations),
never to a web server.
