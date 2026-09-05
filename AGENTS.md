# Agent rules — evgl-lib-core

Owner: `evento-globolo`
Tracking: `DEN-3321`

This repository is the canonical Evento Globolo persistence boundary. Keep public
wire contracts in `evento-globolo/evgl-interfaces`; keep desired SQL, persistence schema,
ORM generation, named database operations, and DPM inputs here.

Use focused feature branches and reviewed pull requests. Never add startup
migration behavior, raw database-handle exports, credentials, or customer data.
Resolve conflicts semantically after reading both histories. The fleet-wide
instructions are in `~/codes/AGENTS.md` and must be followed.
