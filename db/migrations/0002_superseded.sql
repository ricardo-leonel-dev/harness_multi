-- Migration 0002: add the 'superseded' feature status to an already-deployed
-- Postgres mirror, so sync_postgres.sh can upsert features closed with
-- `harness.sh supersede` (without it, upsert_feature rejects the enum value
-- and the row is skipped with a [WARN]).
--
-- Safe to re-run. Run as a top-level statement, not inside BEGIN...COMMIT —
-- see 0001_sdd.sql for why ALTER TYPE ... ADD VALUE needs that.
--
-- Only the status is mirrored: superseded_by/superseded_from and the
-- feature_notes table stay local to harness.db (visible via state/).

alter type feature_status add value if not exists 'superseded';
