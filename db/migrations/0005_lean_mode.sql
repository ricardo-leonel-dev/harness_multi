-- Migration 0005: mirror the lean flow (lean/README.md) to an already-deployed
-- Postgres mirror. Fresh installs get all of it from db/schema.postgres.sql.
--
--   features:    mode ('normal' / 'risk', NULL = no lean flow), plan_approval,
--                plan_approved_by, plan_approved_at. plan_frozen (the risk-mode
--                hash manifest) stays local: it means nothing to a dashboard.
--   session_log: review_status, reviewed_by, reviewed_at, so a dashboard can
--                tell a lean close ('lean') from a reviewer ('approved') or a
--                quick ('quick') one.
--
-- Safe to re-run. Apply db/rpc/upsert_feature.sql and db/rpc/upsert_session.sql
-- after this file (each drops its previous signature first). Until they are
-- applied, sync_postgres.sh retries each row without the new fields and
-- [WARN]s once, so nothing else stops syncing.

alter table features add column if not exists mode text
  constraint features_mode_check check (mode in ('normal', 'risk'));
alter table features add column if not exists plan_approval boolean not null default false;
alter table features add column if not exists plan_approved_by text;
alter table features add column if not exists plan_approved_at timestamptz;

-- Free text, like SQLite (validated in bash): 'approved', 'changes_requested',
-- 'quick' or 'lean'. No CHECK, so a new close path never breaks the sync.
alter table session_log add column if not exists review_status text;
alter table session_log add column if not exists reviewed_by text;
alter table session_log add column if not exists reviewed_at timestamptz;

-- `select *` views freeze their column list when created: re-create them so
-- the new columns show up (create or replace may only append columns, which
-- is all this does).
create or replace view active_features as select * from features where deleted_at is null;
create or replace view active_sessions as select * from session_log where deleted_at is null;

notify pgrst, 'reload schema';
