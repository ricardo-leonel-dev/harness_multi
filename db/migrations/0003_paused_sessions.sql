-- Migration 0003: add session_log.paused_at to an already-deployed Postgres
-- mirror. `block` now pauses its feature's session (paused_at set, closed_at
-- still NULL) so a blocked feature stops occupying the project's single open
-- session slot; `unblock` clears it and resumes the same session. Without
-- this, sync would try to mirror a paused session plus a new active one and
-- hit one_open_session_per_project.
--
-- Safe to re-run. Apply db/rpc/upsert_session.sql (updated, adds p_paused_at)
-- after this file. The old 12-argument upsert_session is dropped first so the
-- new signature doesn't sit next to it as an ambiguous overload.

alter table session_log add column if not exists paused_at timestamptz;

drop index if exists one_open_session_per_project;
create unique index one_open_session_per_project on session_log (project_id)
  where closed_at is null and deleted_at is null and paused_at is null;

drop function if exists upsert_session(text, bigint, text, text, text[], text[], text[], text, text,
  timestamptz, timestamptz, timestamptz);
