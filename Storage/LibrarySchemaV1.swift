//
//  LibrarySchemaV1.swift
//  ResearchBase
//
//  Phase 1, Step 1A (F-04, F-07, F-14)
//
//  Schema version 1 of the library database.
//
//  The SQL below is docs/schema.sql copied word for word, minus the three
//  PRAGMA lines at the top (the migration runner sets the journal mode,
//  foreign keys and `user_version` itself, because PRAGMA journal_mode
//  cannot run inside a transaction).
//
//  RULE (AGENTS.md section 2): never edit this text to change the schema.
//  A change is a NEW migration (version 2, 3, ...) in LibraryMigrations.swift.
//  A test (LibraryStorageTests.testEmbeddedSchemaIsIdenticalToDocsSchemaSql)
//  compares this text with docs/schema.sql so the two cannot drift apart.
//

import Foundation

enum LibrarySchemaV1 {

    static let sql = #"""
-- ResearchBase library schema, version 1
-- File: ResearchBase Library/library.sqlite   (SQLite + WAL, FTS5 built in)
-- Every table that users can delete from has deleted_at (soft delete -> Trash).
-- Every id is a UUID stored as TEXT. Every time is UTC, ISO-8601 TEXT.

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL                  -- app_version, created_at, last_backup_at, last_integrity_at ...
);

-- ---------- Items (papers, books, web pages, datasets, code, reports) ----------
CREATE TABLE items (
  id              TEXT PRIMARY KEY,
  item_type       TEXT NOT NULL CHECK (item_type IN
                   ('article','preprint','conference','book','chapter','thesis',
                    'report','webpage','dataset','software')),
  title           TEXT NOT NULL,
  abstract        TEXT NOT NULL DEFAULT '',
  venue           TEXT NOT NULL DEFAULT '',       -- journal / conference / publisher
  year            INTEGER,
  month           TEXT NOT NULL DEFAULT '',
  volume          TEXT NOT NULL DEFAULT '',
  issue           TEXT NOT NULL DEFAULT '',
  pages           TEXT NOT NULL DEFAULT '',
  publisher       TEXT NOT NULL DEFAULT '',
  edition         TEXT NOT NULL DEFAULT '',
  doi             TEXT,                           -- lower-cased, no URL prefix
  arxiv_id        TEXT,
  url             TEXT NOT NULL DEFAULT '',
  citation_key    TEXT NOT NULL,                  -- stable once used in a draft (see key_locked)
  key_locked      INTEGER NOT NULL DEFAULT 0,
  reading_status  TEXT NOT NULL DEFAULT 'unread' CHECK (reading_status IN ('unread','reading','read')),
  in_queue        INTEGER NOT NULL DEFAULT 0,     -- reading queue
  rating          INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
  language        TEXT NOT NULL DEFAULT '',
  -- capture provenance (browser extension, drag-drop, DOI lookup ...)
  source_url      TEXT NOT NULL DEFAULT '',
  source_kind     TEXT NOT NULL DEFAULT 'manual' CHECK (source_kind IN
                   ('manual','doi','arxiv','url','pdf_drop','import','browser','inbox_folder')),
  captured_at     TEXT,
  review_state    TEXT NOT NULL DEFAULT 'accepted' CHECK (review_state IN ('inbox','accepted')),
  -- published-version / retraction tracking
  published_doi   TEXT,
  retracted       INTEGER NOT NULL DEFAULT 0,
  last_checked_at TEXT,
  reading_seconds INTEGER NOT NULL DEFAULT 0,
  last_page       INTEGER NOT NULL DEFAULT 1,
  added_at        TEXT NOT NULL,
  updated_at      TEXT NOT NULL,
  deleted_at      TEXT
);
CREATE UNIQUE INDEX items_citation_key ON items(lower(citation_key)) WHERE deleted_at IS NULL;
CREATE INDEX items_doi      ON items(doi)      WHERE doi IS NOT NULL;
CREATE INDEX items_arxiv    ON items(arxiv_id) WHERE arxiv_id IS NOT NULL;
CREATE INDEX items_review   ON items(review_state, deleted_at);

-- ---------- Authors as real records ----------
CREATE TABLE creators (
  id        TEXT PRIMARY KEY,
  family    TEXT NOT NULL,                       -- "van der Berg"
  given     TEXT NOT NULL DEFAULT '',
  suffix    TEXT NOT NULL DEFAULT '',            -- "Jr."
  is_org    INTEGER NOT NULL DEFAULT 0,          -- corporate author
  orcid     TEXT,
  norm      TEXT NOT NULL                        -- lower-case, accent-stripped, for matching/search
);
CREATE INDEX creators_norm ON creators(norm);
CREATE TABLE item_creators (
  item_id    TEXT NOT NULL REFERENCES items(id)    ON DELETE CASCADE,
  creator_id TEXT NOT NULL REFERENCES creators(id) ON DELETE RESTRICT,
  role       TEXT NOT NULL DEFAULT 'author' CHECK (role IN ('author','editor','translator')),
  position   INTEGER NOT NULL,
  PRIMARY KEY (item_id, role, position)
);

-- ---------- Tags, collections, saved searches ----------
CREATE TABLE tags (
  id    TEXT PRIMARY KEY,
  name  TEXT NOT NULL UNIQUE COLLATE NOCASE,
  color TEXT NOT NULL DEFAULT ''
);
CREATE TABLE item_tags (
  item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  tag_id  TEXT NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
  PRIMARY KEY (item_id, tag_id)
);
CREATE TABLE collections (
  id         TEXT PRIMARY KEY,
  parent_id  TEXT REFERENCES collections(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  position   INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT
);
CREATE TABLE collection_items (
  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  item_id       TEXT NOT NULL REFERENCES items(id)       ON DELETE CASCADE,
  PRIMARY KEY (collection_id, item_id)
);
CREATE TABLE saved_searches (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  rules_json TEXT NOT NULL,                      -- [{"field":"year","op":">=","value":2020}, ...]
  match_all  INTEGER NOT NULL DEFAULT 1,
  position   INTEGER NOT NULL DEFAULT 0
);

-- ---------- Attachments: several files per item ----------
CREATE TABLE attachments (
  id          TEXT PRIMARY KEY,
  item_id     TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('pdf','supplement','code','slides','data','snapshot','other')),
  is_primary  INTEGER NOT NULL DEFAULT 0,
  label       TEXT NOT NULL DEFAULT '',
  sha256      TEXT NOT NULL,                     -- content fingerprint = file name in files/
  rel_path    TEXT NOT NULL,                     -- relative to the library folder, e.g. files/ab/ab12....pdf
  original_name TEXT NOT NULL DEFAULT '',
  bytes       INTEGER NOT NULL,
  pages       INTEGER,
  has_text    INTEGER NOT NULL DEFAULT 0,        -- text layer present
  ocr_state   TEXT NOT NULL DEFAULT 'none' CHECK (ocr_state IN ('none','queued','done','failed')),
  indexed_at  TEXT,
  added_at    TEXT NOT NULL,
  deleted_at  TEXT
);
CREATE INDEX attachments_item ON attachments(item_id);
CREATE UNIQUE INDEX attachments_sha ON attachments(item_id, sha256);

-- ---------- Annotations live here; the PDF file is never rewritten ----------
CREATE TABLE annotations (
  id            TEXT PRIMARY KEY,
  attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('highlight','underline','area','note')),
  color         TEXT NOT NULL DEFAULT 'yellow',
  page          INTEGER NOT NULL,
  rects_json    TEXT NOT NULL,                   -- [[x,y,w,h], ...] in PDF points
  quote         TEXT NOT NULL DEFAULT '',
  comment       TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  deleted_at    TEXT
);

-- ---------- Thoughts: notes, findings, gaps, problems, ideas in one table ----------
CREATE TABLE thoughts (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('note','finding','gap','problem','idea')),
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',          -- Markdown
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','exploring','done','dropped')),
  priority    INTEGER NOT NULL DEFAULT 0,
  evidence    TEXT NOT NULL DEFAULT '',          -- gaps
  question    TEXT NOT NULL DEFAULT '',          -- problems
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT
);

-- ---------- Literature review ----------
CREATE TABLE reviews (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, question TEXT NOT NULL DEFAULT '',
  synthesis TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE review_themes (
  id TEXT PRIMARY KEY, review_id TEXT NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
  name TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE review_columns (
  id TEXT PRIMARY KEY, review_id TEXT NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
  name TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE review_cells (                       -- comparison matrix: one cell per paper x column
  review_id TEXT NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
  item_id   TEXT NOT NULL REFERENCES items(id)   ON DELETE CASCADE,
  column_id TEXT NOT NULL REFERENCES review_columns(id) ON DELETE CASCADE,
  value     TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (review_id, item_id, column_id)
);

-- ---------- ONE link table for everything ----------
CREATE TABLE links (
  id        TEXT PRIMARY KEY,
  from_type TEXT NOT NULL,                       -- item | thought | experiment | draft | project | task | review | collection
  from_id   TEXT NOT NULL,
  to_type   TEXT NOT NULL,
  to_id     TEXT NOT NULL,
  rel       TEXT NOT NULL DEFAULT 'related' CHECK (rel IN
             ('related','cites','supports','contradicts','uses','extends','part_of','derived_from')),
  note      TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  UNIQUE (from_type, from_id, to_type, to_id, rel)
);
CREATE INDEX links_to ON links(to_type, to_id);  -- "where is this used?" is one indexed lookup

-- ---------- Experiments ----------
CREATE TABLE experiments (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'planned'
   CHECK (status IN ('planned','running','completed','failed','archived')),
  objective TEXT NOT NULL DEFAULT '', hypothesis TEXT NOT NULL DEFAULT '',
  interpretation TEXT NOT NULL DEFAULT '', conclusion TEXT NOT NULL DEFAULT '',
  -- reproducibility record
  code_repo TEXT NOT NULL DEFAULT '', code_commit TEXT NOT NULL DEFAULT '', code_dirty INTEGER NOT NULL DEFAULT 0,
  dataset TEXT NOT NULL DEFAULT '', dataset_version TEXT NOT NULL DEFAULT '', dataset_sha256 TEXT NOT NULL DEFAULT '',
  split_spec TEXT NOT NULL DEFAULT '',
  environment_json TEXT NOT NULL DEFAULT '{}',   -- os, python, packages (pip freeze), cuda, hardware
  config_json TEXT NOT NULL DEFAULT '{}',        -- model, optimizer, learning rate, epochs, batch size
  best_run_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE runs (
  id TEXT PRIMARY KEY, experiment_id TEXT NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
  setting TEXT NOT NULL DEFAULT 'default',        -- runs with the same setting are repeats
  run_number INTEGER NOT NULL, seed INTEGER,
  status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','running','completed','failed')),
  started_at TEXT, completed_at TEXT, config_json TEXT NOT NULL DEFAULT '{}', notes TEXT NOT NULL DEFAULT '',
  source_file TEXT NOT NULL DEFAULT '',           -- set when imported from a log
  code_commit TEXT NOT NULL DEFAULT ''
);
CREATE TABLE metrics (
  id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  name TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL DEFAULT '',
  higher_is_better INTEGER NOT NULL DEFAULT 1, step INTEGER      -- step set for curves
);
CREATE INDEX metrics_run ON metrics(run_id, name);
CREATE TABLE baselines (
  id TEXT PRIMARY KEY, experiment_id TEXT NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
  name TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL DEFAULT '', higher_is_better INTEGER NOT NULL DEFAULT 1,
  source_item_id TEXT REFERENCES items(id)
);

-- ---------- Writing: the text lives in real files; the database tracks them ----------
CREATE TABLE drafts (
  id TEXT PRIMARY KEY, title TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('paper','thesis','report','chapter','other')),
  folder TEXT NOT NULL,                           -- drafts/<id>/  (main.tex, refs.bib, figures/, chapters/)
  main_file TEXT NOT NULL DEFAULT 'main.tex',
  template_id TEXT, template_version TEXT,
  engine TEXT NOT NULL DEFAULT 'latexmk-pdflatex',
  bib_style TEXT NOT NULL DEFAULT 'plainnat',     -- LaTeX .bst name
  csl_style TEXT NOT NULL DEFAULT 'ieee',         -- used for Word / Markdown export
  stage TEXT NOT NULL DEFAULT 'draft' CHECK (stage IN ('draft','submitted','under_review','revision','accepted','published')),
  word_goal INTEGER, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE draft_citations (                     -- rebuilt from the .tex on every save
  draft_id TEXT NOT NULL REFERENCES drafts(id) ON DELETE CASCADE,
  item_id  TEXT REFERENCES items(id),             -- NULL = key not found in the library
  citation_key TEXT NOT NULL, file TEXT NOT NULL, line INTEGER NOT NULL,
  PRIMARY KEY (draft_id, citation_key, file, line)
);
CREATE TABLE draft_snapshots (
  id TEXT PRIMARY KEY, draft_id TEXT NOT NULL REFERENCES drafts(id) ON DELETE CASCADE,
  label TEXT NOT NULL DEFAULT '', auto INTEGER NOT NULL DEFAULT 1,
  words INTEGER NOT NULL DEFAULT 0, bundle_path TEXT NOT NULL,   -- zipped copy of the folder
  created_at TEXT NOT NULL
);
CREATE TABLE draft_comments (
  id TEXT PRIMARY KEY, draft_id TEXT NOT NULL REFERENCES drafts(id) ON DELETE CASCADE,
  file TEXT NOT NULL, line INTEGER NOT NULL, anchor_text TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT 'comment' CHECK (kind IN ('comment','todo')),
  body TEXT NOT NULL, resolved INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
);
CREATE TABLE templates (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL, document_class TEXT NOT NULL,
  needs_class_file INTEGER NOT NULL DEFAULT 0, bundle_path TEXT NOT NULL, bst TEXT NOT NULL DEFAULT '',
  UNIQUE (id, version)
);
CREATE TABLE submissions (
  id TEXT PRIMARY KEY, draft_id TEXT REFERENCES drafts(id), venue TEXT NOT NULL,
  deadline TEXT, submitted_at TEXT, decision_at TEXT,
  stage TEXT NOT NULL DEFAULT 'planned' CHECK (stage IN ('planned','submitted','under_review','revision','accepted','rejected','published')),
  url TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE review_comments (                     -- reviewer comment + your reply
  id TEXT PRIMARY KEY, submission_id TEXT NOT NULL REFERENCES submissions(id) ON DELETE CASCADE,
  round INTEGER NOT NULL DEFAULT 1, reviewer TEXT NOT NULL, comment TEXT NOT NULL,
  reply TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','addressed','disagree')),
  draft_line_ref TEXT NOT NULL DEFAULT ''
);

-- ---------- Projects and tasks ----------
CREATE TABLE projects (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id), title TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'todo' CHECK (status IN ('todo','doing','done')),
  priority TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('low','medium','high')),
  due_at TEXT, remind_at TEXT, completed_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);

-- ---------- Change history, undo and diagnostics ----------
CREATE TABLE changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,
  entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('create','update','delete','restore','merge','import')),
  field TEXT, old_value TEXT, new_value TEXT, batch_id TEXT       -- batch_id groups one user action for undo
);
CREATE INDEX changes_entity ON changes(entity_type, entity_id, at);
CREATE TABLE capture_log (                        -- every paper that arrived from outside the app
  id TEXT PRIMARY KEY, at TEXT NOT NULL, via TEXT NOT NULL CHECK (via IN ('browser','inbox_folder','quick_add','drop')),
  source_url TEXT NOT NULL DEFAULT '', item_id TEXT REFERENCES items(id), result TEXT NOT NULL, detail TEXT NOT NULL DEFAULT ''
);
CREATE TABLE lookup_cache (                       -- metadata answers cached so lookups still work offline
  key TEXT PRIMARY KEY, source TEXT NOT NULL, response_json TEXT NOT NULL, fetched_at TEXT NOT NULL
);

-- ---------- Full-text search (FTS5 ships with macOS SQLite) ----------
CREATE VIRTUAL TABLE fts_items   USING fts5(title, authors, abstract, tags, venue,  content='', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE fts_pdf     USING fts5(text, attachment_id UNINDEXED, page UNINDEXED, content='', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE fts_thought USING fts5(title, body, content='', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE fts_draft   USING fts5(text, draft_id UNINDEXED, file UNINDEXED, content='', tokenize='unicode61 remove_diacritics 2');
"""#
}
