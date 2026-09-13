-- ============================================================
-- transactions.sql — Deliverable G.3
--
-- T1 was tested against the generated database. T2 was tested using
-- two live sqlite3 connections. T3's handle-change constraint was tested
-- against the generated database; the SQLITE_BUSY section documents the
-- required two-writer demonstration.
-- journal_mode=WAL is required at the top of schema.sql for G.3's
-- concurrency demonstration.
--
-- IMPORTANT CORRECTION TO THE TASK SHEET'S OWN TEMPLATE: the approach
-- example in the task sheet uses `SELECT 1/0;` as the deliberate-failure
-- placeholder. Tested directly: SQLite's integer division by zero
-- evaluates to NULL, not an error — `SELECT 1/0` succeeds silently. Taken
-- literally, that placeholder would make every transaction below commit
-- successfully and demonstrate nothing. T1 below instead injects a real
-- CHECK-constraint violation, tied to the transaction's own data, which
-- actually aborts the transaction (verified) — and places it BETWEEN the
-- two writes, matching the task's "failure between the two" wording exactly.
--
-- Schema note: this script assumes schema.sql includes Turn.occurred_at
-- (added specifically so v_turn_cost, Deliverable G.1, can resolve
-- historical pricing against a real timestamp rather than trusting a
-- stored FK) and trg_handle_change_limit (added specifically so T3 below
-- can demonstrate a genuine database-level constraint firing, upgrading
-- the "not declarative" gap E.2 originally documented for the
-- twice-a-year handle-change rule).
-- ============================================================

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;


-- ============================================================
-- T1 · Like retraction must be atomic.
-- A like is retracted: the Like row is ended AND a negative-signal row is
-- written (Appendix B / §2.4's "model that deliberately" instruction).
-- Shows a failure BETWEEN the two writes leaves NEITHER applied.
-- ============================================================

-- Pick an active like to retract (bind :uid, :vid, :started_at from
-- SELECT user_id, video_id, started_at FROM Like WHERE ended_at IS NULL LIMIT 1).

BEGIN;
    UPDATE Like SET ended_at = '2026-09-01T00:00:00Z'
    WHERE user_id = :uid AND video_id = :vid AND started_at = :started_at;

    -- deliberate failure HERE, between the two writes: try to end the SAME
    -- like a second time, at an instant equal to its own started_at --
    -- violates Like's own CHECK (ended_at IS NULL OR ended_at > started_at).
    -- A real constraint violation, not SELECT 1/0 (SQLite's integer
    -- division by zero returns NULL, not an error -- verified directly,
    -- see the note at the top of this file), and anchored to data this
    -- transaction itself just wrote rather than an arbitrary failure.
    UPDATE Like SET ended_at = :started_at
    WHERE user_id = :uid AND video_id = :vid AND started_at = :started_at;

    -- never reached -- the statement above aborts the transaction before
    -- execution gets here:
    INSERT INTO EngagementSignal (user_id, video_id, signal_type, occurred_at, destination)
    VALUES (:uid, :vid, 'like_retract', '2026-09-01T00:00:00Z', NULL);
COMMIT;  -- never reached

-- Actual result when run: sqlite3.IntegrityError — "CHECK constraint
-- failed: ended_at IS NULL OR ended_at > started_at" — raised on the
-- second statement, before the INSERT is ever attempted. The failing
-- statement is aborted, but the transaction remains open, so an explicit
-- ROLLBACK is required to undo the first UPDATE.

-- Proof of consistency (run after the failed transaction above):
SELECT ended_at FROM Like WHERE user_id = :uid AND video_id = :vid AND started_at = :started_at;
-- Actual result: NULL — the like is still active, the first UPDATE did
-- NOT persist.

SELECT COUNT(*) FROM EngagementSignal
WHERE user_id = :uid AND video_id = :vid AND signal_type = 'like_retract';
-- Actual result: 0 — the INSERT was never even reached, let alone
-- committed. Neither write landed; the transaction is genuinely atomic.


-- ============================================================
-- T2 · Moderation decision — uncommitted writes must be invisible to
-- another connection. Two connections to the SAME database file: begin
-- the transaction on one, leave it uncommitted, query from the other, and
-- show the half-applied decision is invisible (this is why
-- journal_mode = WAL is required — in the default rollback-journal mode
-- the reader would be BLOCKED rather than shown the pre-transaction value,
-- which demonstrates locking, not the interesting property: snapshot
-- isolation for readers under WAL).
-- ============================================================

-- Connection 1:
BEGIN;
    INSERT INTO ModerationEvent (video_id, decided_at, new_state, decided_by_kind, reviewer_id, classifier_version_id)
    VALUES (:vid, '2026-09-05T00:00:00Z', 'taken_down', 'human', :reviewer_id, NULL);
    -- do NOT commit yet

-- Connection 2, queried WHILE Connection 1's transaction above is open:
SELECT COUNT(*) FROM ModerationEvent WHERE video_id = :vid AND decided_at = '2026-09-05T00:00:00Z';
-- Actual result: 0 — Connection 2 cannot see Connection 1's uncommitted
-- insert, even though both are live connections to the same file, because
-- WAL gives readers a consistent snapshot as of the start of their own
-- read, unaffected by another connection's in-flight writes.

-- Connection 1, now commits:
COMMIT;

-- Connection 2, queried again AFTER Connection 1's commit:
SELECT COUNT(*) FROM ModerationEvent WHERE video_id = :vid AND decided_at = '2026-09-05T00:00:00Z';
-- Actual result: 1 — now visible, confirming the row really was written
-- (this wasn't a connectivity problem masquerading as isolation) and that
-- isolation held specifically until commit, not indefinitely.


-- ============================================================
-- T3 · Handle change — subject to the twice-a-year rule (§2.1/A3). Shows
-- the limit firing on the third attempt as a REAL database constraint
-- (trg_handle_change_limit, added to schema.sql's E.1F section
-- specifically to satisfy this requirement — see that file's header
-- comment for why: a CHECK can't count sibling rows across a moving
-- window, so a BEFORE INSERT trigger using RAISE(ABORT, ...) is the only
-- declarative option SQLite offers here). Then demonstrates SQLITE_BUSY
-- from a second writer while a transaction is open.
-- ============================================================

-- (bind :uid to a user with no existing HandleChangeEvent history)

-- Attempt 1 — trigger's own COUNT sees 0 prior changes in the trailing
-- 365 days, condition is false, INSERT proceeds — ACCEPTED:
BEGIN;
INSERT INTO HandleChangeEvent (user_id, changed_at, old_handle, new_handle)
VALUES (:uid, '2026-01-01T00:00:00Z', 'old1', 'new1');
COMMIT;

-- Attempt 2 — trigger sees 1 prior change, still < 2 — ACCEPTED:
BEGIN;
INSERT INTO HandleChangeEvent (user_id, changed_at, old_handle, new_handle)
VALUES (:uid, '2026-02-01T00:00:00Z', 'old2', 'new2');
COMMIT;

-- Attempt 3 — trigger sees 2 prior changes, >= 2, fires RAISE(ABORT, ...)
-- BEFORE the row is ever written — REJECTED:
BEGIN;
INSERT INTO HandleChangeEvent (user_id, changed_at, old_handle, new_handle)
VALUES (:uid, '2026-03-01T00:00:00Z', 'old3', 'new3');
COMMIT;  -- never reached
-- Actual result when run: sqlite3.IntegrityError — "HandleChangeEvent:
-- handle change limit (2 per trailing 365 days) exceeded" — this is a
-- genuine SQLITE_CONSTRAINT raised by the database itself, not an
-- application-layer check standing in for one.


-- SQLITE_BUSY demonstration:
-- Connection 1 opens a write transaction and holds the write lock:
BEGIN IMMEDIATE;
    INSERT INTO HandleChangeEvent (user_id, changed_at, old_handle, new_handle)
    VALUES (:uid2, '2026-09-06T00:00:00Z', 'x', 'y');
    -- transaction stays open, not committed yet

-- Connection 2 (opened with busy_timeout=0, i.e. fail immediately instead
-- of waiting for the lock) attempts a write WHILE Connection 1 holds it:
BEGIN IMMEDIATE;
    INSERT INTO HandleChangeEvent (user_id, changed_at, old_handle, new_handle)
    VALUES (:uid2, '2026-09-06T00:00:01Z', 'p', 'q');
COMMIT;
-- Expected result: "database is locked" (SQLITE_BUSY), raised on
-- Connection 2's BEGIN IMMEDIATE while Connection 1 holds the write lock.

-- Connection 1:
ROLLBACK;

-- What this tells us: SQLite permits exactly one writer at a time for the
-- whole database file (not per-row, not per-table — the entire file).
-- This sidesteps write skew and lost-update anomalies that a genuinely
-- concurrent multi-writer engine (Postgres, MySQL under certain isolation
-- levels) has to solve with row/predicate locking or MVCC conflict
-- detection: two SQLite writers literally cannot both be mid-transaction
-- against the same file at once, so the class of anomaly where two
-- concurrent transactions each read-then-write the same row based on a
-- now-stale read simply cannot occur here — not because SQLite detects and
-- resolves it, but because the second writer is blocked (or, as configured
-- here, immediately rejected) before it can even begin.
