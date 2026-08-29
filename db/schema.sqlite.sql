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
    CHECK (status IN ('pending', 'spec_drafting', 'spec_ready', 'in_progress', 'done', 'blocked')),
  source_id TEXT,                             -- external origin id (e.g. a Notion page id), for idempotent intake
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
  deleted_at TEXT
);

-- One row IS both current.md and history.md: filter by closed_at instead of
-- moving/erasing files between two locations.
CREATE UNIQUE INDEX one_open_session_per_project ON session_log(project_id)
  WHERE closed_at IS NULL AND deleted_at IS NULL;

CREATE TABLE session_log_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES session_log(id) ON DELETE CASCADE,
  entry TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

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

CREATE INDEX idx_features_project_status ON features(project_id, status);
CREATE INDEX idx_session_log_project_closed ON session_log(project_id, closed_at);
CREATE INDEX idx_session_entries_session ON session_log_entries(session_id, created_at);
