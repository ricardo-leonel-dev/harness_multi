-- Migration 0004: add the agent_runs table (per-agent duration + token usage,
-- one row per invocation, incl. nested spawns via parent_external_id/
-- spawn_depth) to an already-deployed Postgres mirror. Fresh installs get it
-- from db/schema.postgres.sql directly.
--
-- Safe to re-run. Apply db/rpc/upsert_agent_run.sql after this file; until
-- both are applied, sync_postgres.sh only [WARN]s on the agent_runs step.

-- One row per agent invocation, mirroring SQLite's agent_runs (filled locally
-- by `record-usage`; see db/schema.sqlite.sql for the token column semantics:
-- total_tokens = input + cache_read + cache_write + output, reasoning is a
-- subset of output). Numbers/ids/timestamps only — never transcript content.
create table if not exists agent_runs (
  id bigserial primary key,
  project_id uuid not null references projects(id) on delete cascade,
  local_id bigint not null,   -- agent_runs.id from the SQLite primary
  session_id bigint references session_log(id) on delete set null,
  feature_id bigint references features(id) on delete set null,
  runtime text not null check (runtime in ('claude', 'codex')),
  agent_role text,
  label text,
  external_id text not null,
  parent_external_id text,
  spawn_depth integer,
  model text,
  started_at timestamptz,
  finished_at timestamptz,
  duration_seconds double precision,
  input_tokens bigint,
  cache_read_tokens bigint,
  cache_write_tokens bigint,
  output_tokens bigint,
  reasoning_tokens bigint,
  total_tokens bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index if not exists agent_runs_local_id on agent_runs (project_id, local_id);
create unique index if not exists agent_runs_external_active on agent_runs (project_id, runtime, external_id)
  where deleted_at is null;
create index if not exists idx_agent_runs_feature on agent_runs (feature_id, started_at);
create index if not exists idx_agent_runs_session on agent_runs (session_id);

create or replace view active_agent_runs as select * from agent_runs where deleted_at is null;

notify pgrst, 'reload schema';
