#![forbid(unsafe_code)]
//! Opaque, role-aware SeaORM boundary for evgl.
//!
//! Both `evgl-mash-web` and `evgl-api` reach Postgres through this crate
//! and nothing else. That is what makes avenue 1 of the four-transport
//! contract safe: the projection the web server renders and the one the api
//! server returns are the same query builder compiled twice, so they cannot
//! drift.
//!
//! The boundary is enforced two ways, and the point of both is that a mistake
//! has to defeat *both*:
//!
//! * **Cargo features.** `read-only` is the default. [`WriteContext`] exists
//!   only under `read-write`, and migrations only under `migrate`. A web
//!   server depends on this crate with `default-features = false,
//!   features = ["read-only"]`, so a mutating call is a compile error rather
//!   than something review has to catch.
//! * **Database roles.** The DSN a web server connects with belongs to a role
//!   without `INSERT`, `UPDATE`, `DELETE` or DDL. Features bind the binary;
//!   the role binds the connection.
//!
//! Raw connections do not escape this crate. Consumers call named operations,
//! which is what keeps a query from being written twice, differently, in two
//! services.
//!
//! PostgreSQL and CockroachDB both use SeaORM's PostgreSQL driver;
//! [`DatabaseFlavor`] records which one is on the other end for the places
//! where their behaviour differs.

use sea_orm::{ConnectOptions, ConnectionTrait, Database, DatabaseConnection, DbErr, Statement};
use std::time::Duration;

/// Which PostgreSQL-wire-protocol server is on the other end.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DatabaseFlavor {
    PostgreSql,
    CockroachDb,
}

/// Whether a connection may cross the network in the clear.
///
/// `sqlx` defaults to `sslmode=prefer`, which silently downgrades to plaintext
/// when the server declines TLS — a fallback that looks exactly like success.
/// This crate is the authoritative data boundary, so the default is to refuse
/// a DSN that has not said, out loud, that it wants encryption.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransportPolicy {
    /// Require an explicit `sslmode` of `require`, `verify-ca` or
    /// `verify-full`, except on loopback.
    RequireEncryption,
    /// Accept whatever the DSN asks for. For operators who terminate TLS in a
    /// sidecar or connect over a private socket path.
    AllowPlaintext,
}

/// `sslmode` values that guarantee the session is encrypted.
const ENCRYPTED_SSL_MODES: [&str; 3] = ["require", "verify-ca", "verify-full"];

/// Hosts where plaintext does not leave the machine.
const LOOPBACK_HOSTS: [&str; 4] = ["localhost", "127.0.0.1", "::1", "[::1]"];

/// Replace the password in a DSN with a fixed marker.
///
/// Driver errors quote the DSN they failed on, and those errors end up in logs
/// and issue trackers. Nothing in this crate emits an unredacted URL.
#[must_use]
pub fn redact_dsn(database_url: &str) -> String {
    let Some(scheme_end) = database_url.find("://") else {
        return "<malformed database url>".to_owned();
    };
    let authority_start = scheme_end + 3;
    let authority_end = database_url[authority_start..]
        .find('/')
        .map_or(database_url.len(), |offset| authority_start + offset);
    let authority = &database_url[authority_start..authority_end];
    let Some(at) = authority.rfind('@') else {
        return database_url.to_owned();
    };
    let userinfo = &authority[..at];
    let Some(colon) = userinfo.find(':') else {
        return database_url.to_owned();
    };
    format!(
        "{}{}:***{}",
        &database_url[..authority_start],
        &userinfo[..colon],
        &database_url[authority_start + at..],
    )
}

/// The host portion of a DSN, without userinfo or port.
fn dsn_host(database_url: &str) -> Option<&str> {
    let authority_start = database_url.find("://")? + 3;
    let rest = &database_url[authority_start..];
    let authority_end = rest.find(['/', '?']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let host_with_port = authority
        .rfind('@')
        .map_or(authority, |at| &authority[at + 1..]);
    if let Some(closing) = host_with_port.find(']') {
        return Some(&host_with_port[..=closing]);
    }
    Some(
        host_with_port
            .rfind(':')
            .map_or(host_with_port, |colon| &host_with_port[..colon]),
    )
}

/// The `sslmode` query parameter, lowercased.
fn dsn_ssl_mode(database_url: &str) -> Option<String> {
    let query = database_url.split_once('?')?.1;
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(key, _)| key.eq_ignore_ascii_case("sslmode"))
        .map(|(_, value)| value.to_ascii_lowercase())
}

/// Decide whether a DSN satisfies the policy, without connecting.
fn transport_refusal(database_url: &str, policy: TransportPolicy) -> Option<String> {
    if policy == TransportPolicy::AllowPlaintext {
        return None;
    }
    let host = dsn_host(database_url).unwrap_or_default();
    if LOOPBACK_HOSTS
        .iter()
        .any(|loopback| loopback.eq_ignore_ascii_case(host))
    {
        return None;
    }
    match dsn_ssl_mode(database_url) {
        Some(mode) if ENCRYPTED_SSL_MODES.contains(&mode.as_str()) => None,
        Some(mode) => Some(format!(
            "sslmode={mode} does not guarantee an encrypted session; \
             use require, verify-ca, or verify-full"
        )),
        None => Some(
            "the connection URL does not set sslmode; \
             use require, verify-ca, or verify-full"
                .to_owned(),
        ),
    }
}

/// A read-only handle. The only kind a web server can construct.
pub struct ReadContext {
    connection: DatabaseConnection,
    flavor: DatabaseFlavor,
}

/// A read-write handle. Compiled only under the `read-write` feature.
#[cfg(feature = "read-write")]
pub struct WriteContext {
    connection: DatabaseConnection,
    flavor: DatabaseFlavor,
}

impl ReadContext {
    /// Connect with the default policy: encryption is required off-loopback.
    ///
    /// # Errors
    /// [`DbErr`] if the DSN is refused by the policy or the driver cannot
    /// connect. The error never contains a live password.
    pub async fn connect(
        database_url: &str,
        flavor: DatabaseFlavor,
        max_connections: u32,
    ) -> Result<Self, DbErr> {
        Self::connect_with_policy(
            database_url,
            flavor,
            max_connections,
            TransportPolicy::RequireEncryption,
        )
        .await
    }

    /// Connect with an explicit transport policy.
    ///
    /// # Errors
    /// As [`ReadContext::connect`].
    pub async fn connect_with_policy(
        database_url: &str,
        flavor: DatabaseFlavor,
        max_connections: u32,
        policy: TransportPolicy,
    ) -> Result<Self, DbErr> {
        Ok(Self {
            connection: connect(database_url, max_connections, policy).await?,
            flavor,
        })
    }

    /// Which server is on the other end.
    #[must_use]
    pub const fn flavor(&self) -> DatabaseFlavor {
        self.flavor
    }

    /// The connection, for query builders defined inside this crate.
    ///
    /// `pub(crate)` on purpose: a raw connection that escapes the boundary is
    /// how the same query ends up written twice, differently, in two services.
    pub(crate) const fn connection(&self) -> &DatabaseConnection {
        &self.connection
    }

    /// Round-trip the database.
    ///
    /// # Errors
    /// [`DbErr`] if the query fails.
    pub async fn healthcheck(&self) -> Result<(), DbErr> {
        healthcheck(&self.connection).await
    }
}

#[cfg(feature = "read-write")]
impl WriteContext {
    /// Connect with the default policy: encryption is required off-loopback.
    ///
    /// # Errors
    /// As [`ReadContext::connect`].
    pub async fn connect(
        database_url: &str,
        flavor: DatabaseFlavor,
        max_connections: u32,
    ) -> Result<Self, DbErr> {
        Self::connect_with_policy(
            database_url,
            flavor,
            max_connections,
            TransportPolicy::RequireEncryption,
        )
        .await
    }

    /// Connect with an explicit transport policy.
    ///
    /// # Errors
    /// As [`ReadContext::connect`].
    pub async fn connect_with_policy(
        database_url: &str,
        flavor: DatabaseFlavor,
        max_connections: u32,
        policy: TransportPolicy,
    ) -> Result<Self, DbErr> {
        Ok(Self {
            connection: connect(database_url, max_connections, policy).await?,
            flavor,
        })
    }

    /// Which server is on the other end.
    #[must_use]
    pub const fn flavor(&self) -> DatabaseFlavor {
        self.flavor
    }

    pub(crate) const fn connection(&self) -> &DatabaseConnection {
        &self.connection
    }

    /// Round-trip the database.
    ///
    /// # Errors
    /// [`DbErr`] if the query fails.
    pub async fn healthcheck(&self) -> Result<(), DbErr> {
        healthcheck(&self.connection).await
    }
}

async fn connect(
    database_url: &str,
    max_connections: u32,
    policy: TransportPolicy,
) -> Result<DatabaseConnection, DbErr> {
    if max_connections == 0 {
        return Err(DbErr::Custom(
            "max_connections must be greater than zero".to_owned(),
        ));
    }
    if let Some(refusal) = transport_refusal(database_url, policy) {
        return Err(DbErr::Custom(format!(
            "refusing to connect to {}: {refusal}",
            redact_dsn(database_url)
        )));
    }
    let mut options = ConnectOptions::new(database_url.to_owned());
    options
        .max_connections(max_connections)
        .min_connections(0)
        .connect_timeout(Duration::from_secs(10))
        .acquire_timeout(Duration::from_secs(10))
        .idle_timeout(Duration::from_secs(300))
        .sqlx_logging(false);
    Database::connect(options).await.map_err(|error| {
        // The driver quotes the DSN it failed on; that string must never reach
        // a log with a live password still in it.
        DbErr::Custom(format!(
            "cannot connect to {}: {}",
            redact_dsn(database_url),
            redact_dsn(&error.to_string())
        ))
    })
}

async fn healthcheck(connection: &DatabaseConnection) -> Result<(), DbErr> {
    let backend = connection.get_database_backend();
    connection
        .query_one(Statement::from_string(backend, "SELECT 1"))
        .await
        .map(|_| ())
}

/// Named read operations, shared by `evgl-mash-web` and `evgl-api`.
///
/// This is where evgl's query builders go. Both servers call them, which
/// is what makes avenue 1 and avenues 2-4 return the same projection.
pub mod reads {
    use super::{DbErr, ReadContext};
    use sea_orm::{ConnectionTrait, Statement};

    /// The server's own clock, as a smoke test that the boundary is wired.
    ///
    /// Replace with evgl's real projections; keep the shape — a named
    /// operation taking `&ReadContext`, never a caller-supplied connection.
    ///
    /// # Errors
    /// [`DbErr`] if the query fails.
    pub async fn server_time(context: &ReadContext) -> Result<String, DbErr> {
        let backend = context.connection().get_database_backend();
        let row = context
            .connection()
            .query_one(Statement::from_string(
                backend,
                "SELECT now()::text AS now",
            ))
            .await?
            .ok_or_else(|| DbErr::Custom("now() returned no row".to_owned()))?;
        row.try_get::<String>("", "now")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn database_flavors_are_explicit() {
        assert_ne!(DatabaseFlavor::PostgreSql, DatabaseFlavor::CockroachDb);
    }

    #[test]
    fn a_password_never_survives_redaction() {
        assert_eq!(
            redact_dsn("postgres://evgl:hunter2@db.example.test:5432/evgl?sslmode=require"),
            "postgres://evgl:***@db.example.test:5432/evgl?sslmode=require",
        );
        assert_eq!(
            redact_dsn("postgres://evgl:p@ss:word@db.example.test/evgl"),
            "postgres://evgl:***@db.example.test/evgl",
        );
        // Nothing to redact, nothing changed.
        assert_eq!(
            redact_dsn("postgres://db.example.test/evgl"),
            "postgres://db.example.test/evgl",
        );
        assert_eq!(redact_dsn("not-a-url"), "<malformed database url>");
    }

    #[test]
    fn the_host_is_read_without_userinfo_or_port() {
        assert_eq!(
            dsn_host("postgres://user:pass@db.example.test:5432/evgl"),
            Some("db.example.test"),
        );
        assert_eq!(dsn_host("postgres://localhost/evgl"), Some("localhost"));
        assert_eq!(dsn_host("postgres://[::1]:5432/evgl"), Some("[::1]"));
    }

    #[test]
    fn plaintext_is_refused_off_loopback_unless_the_url_asks_for_tls() {
        let policy = TransportPolicy::RequireEncryption;

        for mode in ENCRYPTED_SSL_MODES {
            let url = format!("postgres://u:p@db.example.test/evgl?sslmode={mode}");
            assert_eq!(transport_refusal(&url, policy), None, "{mode} is encrypted");
        }

        // `prefer` is the dangerous one: it looks like success and is not.
        for mode in ["disable", "allow", "prefer", "PREFER"] {
            let url = format!("postgres://u:p@db.example.test/evgl?sslmode={mode}");
            let refusal =
                transport_refusal(&url, policy).unwrap_or_else(|| panic!("{mode} must be refused"));
            assert!(refusal.contains("verify-full"), "{refusal}");
        }

        let silent = "postgres://u:p@db.example.test/evgl";
        assert!(
            transport_refusal(silent, policy)
                .expect("an unstated sslmode is not a promise")
                .contains("does not set sslmode"),
        );

        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let url = format!("postgres://u:p@{host}:5432/evgl?sslmode=disable");
            assert_eq!(transport_refusal(&url, policy), None, "{host} is loopback");
        }

        assert_eq!(
            transport_refusal(silent, TransportPolicy::AllowPlaintext),
            None,
        );
    }

    #[tokio::test]
    async fn a_refused_url_fails_before_the_driver_sees_the_password() {
        let error = ReadContext::connect(
            "postgres://evgl:hunter2@db.example.test/evgl?sslmode=disable",
            DatabaseFlavor::PostgreSql,
            4,
        )
        .await
        .err()
        .expect("plaintext off-loopback is refused");
        let message = error.to_string();
        assert!(!message.contains("hunter2"), "{message}");
        assert!(message.contains("sslmode=disable"), "{message}");
    }

    #[tokio::test]
    async fn a_zero_sized_pool_is_refused() {
        let error = ReadContext::connect(
            "postgres://localhost/evgl",
            DatabaseFlavor::CockroachDb,
            0,
        )
        .await
        .err()
        .expect("a pool of zero cannot serve anything");
        assert!(error.to_string().contains("max_connections"));
    }
}
