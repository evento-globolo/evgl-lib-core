//! Canonical Evento Globolo persistence boundary.
//!
//! This crate separates contracts, bounded reads, API-owned writes, and
//! operator-owned migration planning. It never runs schema changes at service
//! startup and never exports a raw SeaORM connection.

#[cfg(feature = "read")]
pub mod capabilities;
#[cfg(feature = "contracts")]
pub mod contracts;
#[cfg(feature = "migrator")]
pub mod dpm;

#[cfg(feature = "write")]
pub use capabilities::WriteContext;
#[cfg(feature = "read")]
pub use capabilities::{
    AccessScope, ActorContext, CapabilityError, DatabaseFlavor, ReadContext, TenantContext,
};
