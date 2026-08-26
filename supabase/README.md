# HUMANITY/1 Supabase backend baseline

This directory is a source-control baseline of the production Supabase backend used by HUMANITY/1.

## Safety
- No secret values are stored here.
- Runtime credentials remain Supabase Edge Function environment secrets.
- `index.html` is intentionally untouched.
- This baseline does not perform or authorize the final production reset.

## Production project
Supabase project ref: `xwcmzsoydgeybjntqljv`

## Security invariant
A permanent mark must never be inserted unless a successful real server-side payment has been independently verified and the complete purchased batch can be sealed atomically.

## Layout
- `functions/`: source snapshots of security-critical active Edge Functions.
- `migrations/MIGRATION_HISTORY.md`: production migration history visible through Supabase.
- `SECURITY_BASELINE.md`: current database enforcement and review notes.

Historical migration SQL bodies were not reconstructable through the connected Supabase migration-list API. We therefore preserve the authoritative migration identifiers and current live implementation without inventing historical SQL. Future schema migrations should be committed as SQL before deployment.
