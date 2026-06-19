# Supabase backend — source of record

Captured **read-only** from the live project on **2026-06-19** to kill the "no canonical
source" risk (CODE_AUDIT_2026-06-19.md, item #1): before this, the edge-function code and
schema existed only in the live deploy, and the OneDrive `context/` copies had drifted from
live. An AI session that trusted those stale copies could have silently regressed production.

**The LIVE Supabase project is the source of truth, not this folder.** This is a snapshot for
diffing and reference. Refresh it from live before relying on it, and never deploy *from* here
blindly. This folder is excluded from the Vercel deploy via `../.vercelignore` (it is not served
at portal.blacklabelleads.app).

Project ref: `hqiyxeriugywlkbcuasu`

## What's here

| Path | What it is |
|---|---|
| `functions/<slug>/index.ts` | Verbatim live edge-function source (7 functions). |
| `schema-types.ts` | Generated TypeScript types — full current schema shape (16 tables, the `vault_overview` view, ~70 RPCs). |
| `schema-migrations.sql` | Applied-migration DDL history (closest available equivalent to `pg_dump --schema-only`). |
| `migrations-manifest.json` | Version + name index of all applied migrations. |

## Edge-function versions at capture (verify against live `ezbr_sha256`)

A future session can confirm the committed source still matches live by comparing each
function's live `ezbr_sha256` (from `list_edge_functions`) to the value below.

| Function | Version | ezbr_sha256 |
|---|---|---|
| stripe-webhook | 13 | bc4b1690196d330a557553c059e1d825af55e7c82b34a1dafa92d8509cb106b4 |
| start-agent-billing | 5 | faa49dafb7c29aab36b64b8e0691c3c42f893a20acc582d32b67db945794eda0 |
| capture-lead | 6 | 334b939158d85a0cb03ced05b3b50e29afc60dae98a1374dc8abf95c3975f0aa |
| capture-waitlist | 4 | f3eba6b0f8adf940815efd1d2b6fcbb7c3b6df84dc6c5ea316f9884966808158 |
| create-reserve-checkout | 4 | d858a7847bfdd3a5ea208298f761724af22e73403c1731e6b7a4a78816d2e9e7 |
| billing-portal | 4 | 59de968d5e29956ca83097474b8a61bce6091f192fc5b0681e147c1c19fc674b |
| notify-agent | 3 | 06bff2929fd6a17688b12ff3b671e4b2046d6349b86ed0a81821d712b68fe1c6 |

## Caveats

- **Not a true `pg_dump`.** A real `pg_dump --schema-only` needs the database connection string
  (only Colton has it); the MCP can't produce one. `schema-migrations.sql` (migration DDL) +
  `schema-types.ts` (current shape) are the faithful read-only equivalents.
- Secrets are **not** in this source — the functions read them from `Deno.env` (e.g.
  `STRIPE_SECRET_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `TWILIO_*`, `NOTIFY_SECRET`).
- The schema may have changed after capture (a parallel session was hardening the DB the same
  day: pinned `search_path` on ~31 SECURITY DEFINER functions, revoked leftover anon grants,
  added 4 FK indexes). Re-capture after any further DB change.
