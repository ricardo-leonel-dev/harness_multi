-- Harness local primary store (SQLite).
-- Applied once per installed project by install.sh to create harness.db.
-- Table/column names mirror db/schema.postgres.sql so the mirror sync is a
-- near-mechanical row copy rather than a data-model translation.

PRAGMA foreign_keys = ON;

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  slug TEXT NOT NULL,
  description TEXT,
  one_feature_at_a_time INTEGER NOT NULL DEFAULT 1,
  require_tests_to_close INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

CREATE UNIQUE INDEX projects_slug_active ON projects(slug) WHERE deleted_at IS NULL;

CREATE TABLE features (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  feature_number INTEGER NOT NULL,
  name TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  acceptance TEXT NOT NULL DEFAULT '[]',      -- JSON array; SQLite has no native array type
  sdd INTEGER NOT NULL DEFAULT 0,             -- opt-in: does this feature require an approved spec first?
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'spec_drafting', 'spec_ready', 'in_progress', 'done', 'blocked', 'superseded')),
  source_id TEXT,                             -- external origin id (e.g. a Notion page id), for idempotent intake
  depends_on TEXT NOT NULL DEFAULT '[]',      -- JSON array of local feature names that must be 'done' first
  superseded_by TEXT,                         -- name of the feature that absorbed this one (status='superseded')
  superseded_from TEXT,                       -- status before supersede, restored by unsupersede
  size TEXT NOT NULL DEFAULT 'normal',        -- 'normal' or 'small' (validated in bash); small may close via log-out --quick
  request TEXT,                               -- the user's request verbatim (add-feature --request, Notion card text)
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

CREATE UNIQUE INDEX features_number_active ON features(project_id, feature_number) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX features_name_active ON features(project_id, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX features_source_id_active ON features(project_id, source_id)
  WHERE deleted_at IS NULL AND source_id IS NOT NULL;

-- Enforces rules.one_feature_at_a_time as a hard constraint instead of a convention.
CREATE UNIQUE INDEX one_in_progress_per_project ON features(project_id)
  WHERE status = 'in_progress' AND deleted_at IS NULL;

CREATE TABLE session_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  feature_id INTEGER REFERENCES features(id) ON DELETE SET NULL,
  agent TEXT NOT NULL,
  plan TEXT DEFAULT '[]',        -- JSON array
  next_step TEXT DEFAULT '[]',   -- JSON array
  changes TEXT,                  -- JSON array, filled at log-out
  verification TEXT,
  closure TEXT,
  review_status TEXT,            -- NULL until a reviewer records a verdict via record-review;
                                  -- 'approved' or 'changes_requested' (validated in bash, not a DB CHECK)
  reviewed_by TEXT,
  reviewed_at TEXT,
  started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  closed_at TEXT,                -- NULL = "current session"; set = a "history" entry
  paused_at TEXT,                -- set by `block`, cleared by `unblock`: the session stays open
                                  -- (closed_at NULL) but stops occupying the project's slot
  held_at TEXT,                  -- set by `hold`, cleared by `unhold`: the session keeps the slot
                                  -- but log-out refuses it, so the work stops until the user decides
  deleted_at TEXT
);

-- One row IS both current.md and history.md: filter by closed_at instead of
-- moving/erasing files between two locations. Paused sessions (their feature
-- is blocked) are excluded so a block doesn't stall the whole project.
CREATE UNIQUE INDEX one_open_session_per_project ON session_log(project_id)
  WHERE closed_at IS NULL AND deleted_at IS NULL AND paused_at IS NULL;

CREATE TABLE session_log_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES session_log(id) ON DELETE CASCADE,
  entry TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

-- Feature-level notes that don't belong to any session (append-log --feature,
-- supersede/unsupersede audit entries) — e.g. a note written after the
-- feature's last session closed, or on a feature that never had one.
CREATE TABLE feature_notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  feature_id INTEGER NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  entry TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

CREATE INDEX idx_feature_notes_feature ON feature_notes(feature_id, created_at);

-- Metadata about a feature's spec-driven-development artifacts. Content
-- (requirements.md/design.md/tasks.md) lives as git-tracked files on disk at
-- specs/<name>/ — this table never duplicates that prose, it only tracks the
-- lifecycle (drafting/ready/approved) and a durable approval record, since
-- that's the one thing a human-approval gate can't recover from files alone.
CREATE TABLE specs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  feature_id INTEGER NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  path TEXT NOT NULL,                          -- "specs/<name>", stored explicitly so a future
                                                -- feature rename doesn't silently orphan this row
  status TEXT NOT NULL DEFAULT 'drafting'
    CHECK (status IN ('drafting', 'ready', 'approved')),
  requirements_count INTEGER,                  -- parsed at mark-spec-ready time
  tasks_count INTEGER,
  drafted_by TEXT,                             -- the spec_author session's agent string
  ready_at TEXT,
  approved_at TEXT,                            -- NULL until approve-spec runs
  approved_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

CREATE UNIQUE INDEX specs_feature_active ON specs(feature_id) WHERE deleted_at IS NULL;

-- One row per agent invocation (leader/main session, implementer, reviewer,
-- spec_author, research/nested spawns) read from Claude Code transcripts or
-- Codex CLI rollouts by scripts/agent_usage.py (record-usage). Numbers,
-- role, model, timestamps and ids only — never prompt/transcript content.
-- Token columns (NULL when the runtime doesn't report them):
--   input_tokens       uncached input (Codex: input_tokens - cached - cache_write)
--   cache_read_tokens  Claude cache_read_input_tokens / Codex cached_input_tokens
--   cache_write_tokens Claude cache_creation_input_tokens / Codex cache_write_input_tokens
--   output_tokens      output incl. reasoning (Codex reasoning is a subset of it)
--   reasoning_tokens   Codex reasoning_output_tokens; NULL for Claude (not reported)
--   total_tokens       input + cache_read + cache_write + output (Claude: summed;
--                      Codex: its own cumulative total_tokens, the same quantity)
-- duration_seconds = finished_at - started_at of the transcript (first to last
-- event): an agent interval, not CPU time. Summed durations are agent effort,
-- not wall time (see harness/instructions/timing.md).
CREATE TABLE agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id INTEGER REFERENCES session_log(id) ON DELETE SET NULL,  -- harness session whose window contains the run
  feature_id INTEGER REFERENCES features(id) ON DELETE SET NULL,     -- that session's feature
  runtime TEXT NOT NULL CHECK (runtime IN ('claude', 'codex')),
  agent_role TEXT,                             -- 'leader' for a main session; subagent type otherwise
  label TEXT,                                  -- Claude meta.json description / Codex agent_nickname or agent_path
  external_id TEXT NOT NULL,                   -- Claude session/agent id, Codex thread id
  parent_external_id TEXT,                     -- spawning session/thread id (NULL for depth 0)
  spawn_depth INTEGER,                         -- 0 = top-level leader/main session
  model TEXT,
  started_at TEXT,
  finished_at TEXT,
  duration_seconds REAL,
  input_tokens INTEGER,
  cache_read_tokens INTEGER,
  cache_write_tokens INTEGER,
  output_tokens INTEGER,
  reasoning_tokens INTEGER,
  total_tokens INTEGER,
  source_path TEXT,                            -- transcript/rollout file the numbers came from (local only: never mirrored)
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

CREATE UNIQUE INDEX agent_runs_external_active ON agent_runs(project_id, runtime, external_id)
  WHERE deleted_at IS NULL;
CREATE INDEX idx_agent_runs_feature ON agent_runs(feature_id, started_at);
CREATE INDEX idx_agent_runs_session ON agent_runs(session_id);

-- Incremental record-usage bookkeeping (local only: never mirrored to Postgres).
-- One row per transcript/rollout already parsed; record-usage skips a file whose
-- mtime_ns and size still match (--full ignores this table).
CREATE TABLE agent_usage_files (
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  path TEXT NOT NULL,                          -- transcript/rollout file record-usage last parsed
  mtime_ns INTEGER NOT NULL,                   -- change key: unchanged mtime+size => skipped
  size INTEGER NOT NULL,
  recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (project_id, path)
);

-- Short lessons worth carrying between features (harness.sh learn/recall/forget).
-- Never loaded automatically: the leader recalls at most 5 matching notes at claim.
CREATE TABLE learnings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  feature_id INTEGER REFERENCES features(id) ON DELETE SET NULL,  -- feature it came from, if any
  note TEXT NOT NULL,                                             -- at most 300 characters
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT                                                 -- set by forget
);

CREATE INDEX idx_features_project_status ON features(project_id, status);
CREATE INDEX idx_session_log_project_closed ON session_log(project_id, closed_at);
CREATE INDEX idx_session_entries_session ON session_log_entries(session_id, created_at);
