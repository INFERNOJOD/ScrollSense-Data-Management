-- ============================================================
-- schema.sql — E.1A: AppUser, interests, account-status
-- ============================================================

PRAGMA foreign_keys = ON;   -- FK enforcement is per-connection in SQLite — set here and in generator/query scripts
PRAGMA journal_mode = WAL;  -- needed for G.3's concurrency demo; a database-file-level
                            -- setting, not per-connection, but going here per §0.1's
                            -- instruction rather than relying on transactions.sql to set
                            -- it later (transactions.sql re-sets it too, harmlessly)

-- ------------------------------------------------------------
-- TYPE AFFINITY CHECK (§0.1 / E.1) — tested directly, not assumed.
--
-- INSERT INTO Video (video_id, owner_id, duration_ms, caption, uploaded_at)
--   VALUES (999, 1, 'not-a-number', 'x', '2026-01-01T00:00:00Z');
-- Result: sqlite3.IntegrityError — "CHECK constraint failed:
-- duration_ms BETWEEN 20000 AND 90000".
--
-- The column's INTEGER affinity does NOT reject the text — SQLite only
-- tries to coerce it, and 'not-a-number' can't be coerced, so it's stored
-- as-is with TEXT storage class inside an INTEGER-affinity column
-- (confirmed with typeof()). What actually rejects the insert is the CHECK,
-- and specifically because it's a two-sided BETWEEN: SQLite's cross-type
-- ordering rule (NULL < INTEGER/REAL < TEXT < BLOB) means any TEXT value
-- sorts ABOVE every number, so 'not-a-number' <= 90000 is false and the
-- CHECK fails — not because SQLite understood the value was garbage.
--
-- Tested the same thing against a one-sided CHECK (turn_seq >= 1): the
-- SAME text value is accepted. 'hello' >= 1 evaluates true under that same
-- ordering rule (TEXT > any INTEGER), so a lower-bound-only CHECK gives
-- zero protection against non-numeric garbage — only a two-sided BETWEEN
-- happens to catch it, and only as a side effect of comparison ordering,
-- not because it was designed to validate type. Columns in this schema
-- with only a one-sided CHECK (turn_seq, position, latency_ms,
-- feed_position and similar) are NOT actually protected against this —
-- worth flagging honestly rather than assuming BETWEEN's behaviour
-- generalises. Correctness here rests almost entirely on CHECK constraints,
-- not on the declared types, and even CHECKs don't uniformly cover this
-- failure mode. STRICT tables (3.37+) would close this gap outright by
-- rejecting the insert before any CHECK runs, at the cost of DATETIME/
-- VARCHAR(n)-style declarations no longer parsing — not used here, since
-- every timestamp/string column below is already declared as bare TEXT.
--
-- CLOSED VALUE SETS: small, stable sets (account_state, decided_by_kind,
-- signal_type, destination, thumbs, is_licensed/errored/reached_end as
-- 0/1) are CHECK (col IN (...)) — cheap, invisible, fine for a handful of
-- values nobody's asking to extend. new_state (moderation) is the one case
-- where this trade is genuinely debatable: Trust & Safety, per §2.6, are
-- the named consumer of this exact column, and a CHECK IN list means
-- adding a state later needs an ALTER — which SQLite can't do to add a
-- constraint (§0.1) — so it'd mean rebuilding the table. Kept it as CHECK
-- IN anyway for this assignment's scope, since the brief lists a fixed
-- five-state set with no indication it's growing, but a lookup table
-- would be the safer call if that changed. ClassifierVersion and
-- PromptTemplateVersion are proper lookup tables instead of CHECK lists,
-- since those sets are genuinely open-ended and referenced by FK already.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- AppUser
-- ------------------------------------------------------------
CREATE TABLE AppUser (
    user_id               INTEGER PRIMARY KEY,
    auth_method           TEXT    NOT NULL
                           CHECK (auth_method IN ('phone','google')),
    phone_number          TEXT,                       -- NULL means "not this auth method"
    google_account_id     TEXT,                        -- NULL means "not this auth method"
    handle                TEXT    NOT NULL,
    display_name          TEXT    NOT NULL,
    account_state         TEXT    NOT NULL DEFAULT 'active'
                           CHECK (account_state IN ('active','deactivated','pending_deletion')),
    deletion_requested_at TEXT,                        -- NULL means "not currently pending deletion"
    created_at            TEXT    NOT NULL,

    -- exactly one auth identifier populated, matching auth_method (extends C.1's
    -- domain declaration — additional physical constraint, see E.2 trace)
    CHECK (
        (auth_method = 'phone'  AND phone_number      IS NOT NULL AND google_account_id IS NULL)
        OR
        (auth_method = 'google' AND google_account_id IS NOT NULL AND phone_number      IS NULL)
    ),

    -- deletion_requested_at populated iff account is pending_deletion
    CHECK (
        (account_state = 'pending_deletion' AND deletion_requested_at IS NOT NULL)
        OR
        (account_state != 'pending_deletion' AND deletion_requested_at IS NULL)
    )
);

-- A3: handle must be unique case-insensitively among active accounts.
-- Partial unique index enforces this only for active accounts (NOCASE folds ASCII only).
CREATE UNIQUE INDEX ux_appuser_handle_active
    ON AppUser (handle COLLATE NOCASE)
    WHERE account_state = 'active';

-- ------------------------------------------------------------
-- HandleChangeEvent — exists to enforce "at most twice a year" (A3/§2.1)
-- ------------------------------------------------------------
CREATE TABLE HandleChangeEvent (
    user_id     INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    changed_at  TEXT    NOT NULL,
    old_handle  TEXT    NOT NULL,
    new_handle  TEXT    NOT NULL,
    PRIMARY KEY (user_id, changed_at)
    -- "≤2x per trailing 12 months" is enforced by trg_handle_change_limit
);

CREATE TRIGGER trg_handle_change_limit
BEFORE INSERT ON HandleChangeEvent
FOR EACH ROW
BEGIN
    -- NOTE (fixed): this used to compare `changed_at` against
    -- `datetime(NEW.changed_at, '-365 days')` with a plain string `>`.
    -- `changed_at` is stored ISO-8601 with a 'T' and trailing 'Z'
    -- ('2026-03-01T00:00:00Z'), but SQLite's datetime() always OUTPUTS
    -- space-separated, no 'Z' ('2026-03-01 00:00:00') — exactly the
    -- mismatch this project's own convention (julianday() everywhere,
    -- see queries.sql's header note) exists to avoid. Since 'T' (0x54)
    -- always sorts above ' ' (0x20), any HandleChangeEvent landing on the
    -- exact calendar date of the 365-day cutoff got treated as "within
    -- the window" regardless of time-of-day — including changes that
    -- actually happened just over 365 days ago. Confirmed directly:
    -- changed_at='2025-06-01T08:00:00Z' against a cutoff instant of
    -- '2026-06-01T14:00:00Z' minus 365 days is 365.25 real days back (so
    -- should be excluded), but the old string comparison counted it as
    -- within window anyway. Fixed by going through julianday(), matching
    -- how every date comparison elsewhere in this project is done.
    SELECT CASE
        WHEN (
            SELECT COUNT(*)
            FROM HandleChangeEvent
            WHERE user_id = NEW.user_id
              AND julianday(changed_at) > julianday(NEW.changed_at) - 365
              AND changed_at <= NEW.changed_at
        ) >= 2
        THEN RAISE(ABORT, 'Handle can be changed at most twice in 365 days')
    END;
END;

-- ------------------------------------------------------------
-- Category — static reference list
-- ------------------------------------------------------------
CREATE TABLE Category (
    category_id INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE
);

-- ------------------------------------------------------------
-- UserDeclaredInterest — one-time signup declaration, append-only
-- ------------------------------------------------------------
CREATE TABLE UserDeclaredInterest (
    user_id     INTEGER NOT NULL REFERENCES AppUser(user_id)  ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES Category(category_id) ON DELETE RESTRICT,
    declared_at TEXT    NOT NULL,
    PRIMARY KEY (user_id, category_id)
);

-- ------------------------------------------------------------
-- InferredInterest — weekly ML refresh, append-only (one row per week)
-- ------------------------------------------------------------
CREATE TABLE InferredInterest (
    user_id     INTEGER NOT NULL REFERENCES AppUser(user_id)  ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES Category(category_id) ON DELETE RESTRICT,
    as_of_week  TEXT    NOT NULL,
    score       REAL    NOT NULL CHECK (score BETWEEN 0.0 AND 1.0),
    PRIMARY KEY (user_id, category_id, as_of_week)
);

-- ------------------------------------------------------------
-- InterestSuppression — A13: reversible, validity-interval strategy
-- ------------------------------------------------------------
CREATE TABLE InterestSuppression (
    user_id         INTEGER NOT NULL REFERENCES AppUser(user_id)  ON DELETE CASCADE,
    category_id     INTEGER NOT NULL REFERENCES Category(category_id) ON DELETE RESTRICT,
    suppressed_at   TEXT    NOT NULL,
    unsuppressed_at TEXT,                       -- NULL means "still suppressed"
    PRIMARY KEY (user_id, category_id, suppressed_at),
    CHECK (unsuppressed_at IS NULL OR unsuppressed_at > suppressed_at)
    -- non-overlap across suppression intervals: not declarative, same class as
    -- CreatorTierPeriod's non-overlap rule in Deliverable D
);

-- ------------------------------------------------------------
-- AccountStatusEvent — append-only log of every state transition
-- ------------------------------------------------------------
CREATE TABLE AccountStatusEvent (
    user_id    INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    changed_at TEXT    NOT NULL,
    new_state  TEXT    NOT NULL
               CHECK (new_state IN ('active','deactivated','pending_deletion')),
    PRIMARY KEY (user_id, changed_at)
);


-- ============================================================
-- schema.sql — E.1B: Creator tier, video/content, moderation
-- ============================================================

-- ------------------------------------------------------------
-- CreatorTierPeriod — B.2: validity intervals
-- ------------------------------------------------------------
CREATE TABLE CreatorTierPeriod (
    creator_id INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    valid_from TEXT    NOT NULL,
    valid_to   TEXT,                    -- NULL means "this is the creator's current tier, still open"
    tier       TEXT    NOT NULL,
    PRIMARY KEY (creator_id, valid_from),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
    -- Non-overlap across a creator's periods is not declarative;
    -- candidate for the overlap-prevention trigger.
);

-- ------------------------------------------------------------
-- Hashtag — static dictionary, normalised text
-- ------------------------------------------------------------
CREATE TABLE Hashtag (
    hashtag_id INTEGER PRIMARY KEY,
    text       TEXT NOT NULL UNIQUE
);

-- ------------------------------------------------------------
-- Video
-- ------------------------------------------------------------
CREATE TABLE Video (
    video_id       INTEGER PRIMARY KEY,
    owner_id       INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    duration_ms    INTEGER NOT NULL CHECK (duration_ms BETWEEN 20000 AND 90000),
    caption        TEXT    NOT NULL,
    audio_track_id INTEGER REFERENCES AudioTrack(track_id)
                   ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
                   -- NULL means "no audio track attached" (§2.2's "optional audio track")
    uploaded_at    TEXT    NOT NULL
);

-- ------------------------------------------------------------
-- AudioTrack
-- ------------------------------------------------------------
CREATE TABLE AudioTrack (
    track_id        INTEGER PRIMARY KEY,
    origin_video_id INTEGER REFERENCES Video(video_id)
                    ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
                    -- NULL means "licensed catalogue track, didn't originate from any video" (A5)
    is_licensed     INTEGER NOT NULL CHECK (is_licensed IN (0,1))
);

-- ------------------------------------------------------------
-- VideoHashtag — M:N junction
-- ------------------------------------------------------------
CREATE TABLE VideoHashtag (
    video_id   INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    hashtag_id INTEGER NOT NULL REFERENCES Hashtag(hashtag_id) ON DELETE RESTRICT,
    PRIMARY KEY (video_id, hashtag_id)
);

-- ------------------------------------------------------------
-- ClassifierVersion — immutable, append-only
-- ------------------------------------------------------------
CREATE TABLE ClassifierVersion (
    classifier_version_id INTEGER PRIMARY KEY,
    name                  TEXT NOT NULL,
    released_at           TEXT NOT NULL
);

-- ------------------------------------------------------------
-- ModerationEvent — append-only, exclusive-arc decision-maker
-- ------------------------------------------------------------
CREATE TABLE ModerationEvent (
    video_id              INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    decided_at             TEXT    NOT NULL,
    new_state              TEXT    NOT NULL
                            CHECK (new_state IN
                                ('pending','live','age_restricted','demoted','taken_down')),
    decided_by_kind        TEXT    NOT NULL
                            CHECK (decided_by_kind IN ('human','automated')),
    reviewer_id            INTEGER REFERENCES AppUser(user_id) ON DELETE RESTRICT,
                           -- NULL means "not the human path" — populated iff decided_by_kind='human'
    classifier_version_id  INTEGER REFERENCES ClassifierVersion(classifier_version_id)
                            ON DELETE RESTRICT,
                           -- NULL means "not the automated path" — populated iff decided_by_kind='automated'

    PRIMARY KEY (video_id, decided_at),

    CHECK (
        (decided_by_kind = 'human'
         AND reviewer_id IS NOT NULL
         AND classifier_version_id IS NULL)
        OR
        (decided_by_kind = 'automated'
         AND classifier_version_id IS NOT NULL
         AND reviewer_id IS NULL)
    )

    -- A15: every video must have >=1 moderation event.
    -- Enforced by inserting the first event in the same transaction
    -- as the Video row; a normal FK/CHECK cannot enforce child existence.
);


-- ============================================================
-- E.1C: Follow/Block/Mute + impressions/watch/engagement
-- ============================================================

-- ------------------------------------------------------------
-- Follow — validity intervals
-- ------------------------------------------------------------
CREATE TABLE Follow (
    follower_id  INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    followee_id  INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at   TEXT    NOT NULL,
    ended_at     TEXT,     -- NULL means "still following, hasn't ended"
    ended_reason TEXT      -- NULL alongside ended_at IS NULL; see CHECK below for the pairing
                 CHECK (ended_reason IN ('unfollowed','block')),

    PRIMARY KEY (follower_id, followee_id, started_at),

    CHECK (follower_id != followee_id),
    CHECK (ended_at IS NULL OR ended_at > started_at),

    CHECK (
        (ended_at IS NULL AND ended_reason IS NULL)
        OR
        (ended_at IS NOT NULL AND ended_reason IS NOT NULL)
    )

    -- Non-overlap of intervals for the same pair is not declarative.
);

-- ------------------------------------------------------------
-- Block — validity intervals
-- ------------------------------------------------------------
CREATE TABLE Block (
    blocker_id   INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    blocked_id   INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    blocked_at   TEXT    NOT NULL,
    unblocked_at TEXT,     -- NULL means "block still active"

    PRIMARY KEY (blocker_id, blocked_id, blocked_at),

    CHECK (blocker_id != blocked_id),
    CHECK (unblocked_at IS NULL OR unblocked_at > blocked_at)

    -- Breaking existing follows in both directions requires
    -- cross-table trigger/application logic.
);

-- ------------------------------------------------------------
-- Mute — validity intervals
-- ------------------------------------------------------------
CREATE TABLE Mute (
    muter_id   INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    muted_id   INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    muted_at   TEXT    NOT NULL,
    unmuted_at TEXT,       -- NULL means "mute still active"

    PRIMARY KEY (muter_id, muted_id, muted_at),

    CHECK (muter_id != muted_id),
    CHECK (unmuted_at IS NULL OR unmuted_at > muted_at)
);

-- ------------------------------------------------------------
-- Impression — append-only event
-- ------------------------------------------------------------
CREATE TABLE Impression (
    impression_id            INTEGER PRIMARY KEY,
    user_id                  INTEGER NOT NULL
                             REFERENCES AppUser(user_id)
                             ON DELETE CASCADE,

    video_id                 INTEGER NOT NULL
                             REFERENCES Video(video_id)
                             ON DELETE CASCADE,

    shown_at                 TEXT NOT NULL,

    feed_position            INTEGER NOT NULL
                             CHECK (feed_position >= 0),

    ranking_model_version    TEXT NOT NULL,

    source_recommendation_id INTEGER
                             REFERENCES Recommendation(recommendation_id)
                             ON DELETE SET NULL
                             DEFERRABLE INITIALLY DEFERRED
                             -- NULL means "organic impression, not sourced from a recommendation"
);

CREATE UNIQUE INDEX ux_impression_natural_key
    ON Impression (user_id, video_id, shown_at);


-- ------------------------------------------------------------
-- ViewSegment — append-only; new row per loop
-- ------------------------------------------------------------
CREATE TABLE ViewSegment (
    impression_id INTEGER NOT NULL REFERENCES Impression(impression_id) ON DELETE CASCADE,
    segment_seq   INTEGER NOT NULL CHECK (segment_seq >= 1),
    started_at    TEXT    NOT NULL,
    ended_at      TEXT,      -- NULL means "segment still in progress, not closed off yet"
    reached_end   INTEGER NOT NULL CHECK (reached_end IN (0,1)),

    PRIMARY KEY (impression_id, segment_seq),

    CHECK (ended_at IS NULL OR ended_at >= started_at)
);

-- ------------------------------------------------------------
-- Like — validity intervals; retraction ends the row
-- ------------------------------------------------------------
CREATE TABLE Like (
    user_id    INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    video_id   INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    started_at TEXT    NOT NULL,
    ended_at   TEXT,

    PRIMARY KEY (user_id, video_id, started_at),

    CHECK (ended_at IS NULL OR ended_at > started_at)
);

-- ------------------------------------------------------------
-- EngagementSignal — append-only
-- ------------------------------------------------------------
CREATE TABLE EngagementSignal (
    user_id     INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    video_id    INTEGER NOT NULL REFERENCES Video(video_id) ON DELETE CASCADE,
    signal_type TEXT    NOT NULL
                CHECK (signal_type IN
                    ('save','share','comment','follow_from_feed',
                     'not_interested','report','like_retract')),
    occurred_at TEXT NOT NULL,
    destination TEXT
                CHECK (destination IN
                    ('whatsapp','instagram','copied_link')),

    PRIMARY KEY (user_id, video_id, signal_type, occurred_at),

    CHECK (
        (signal_type = 'share' AND destination IS NOT NULL)
        OR
        (signal_type != 'share' AND destination IS NULL)
    )
);

-- ============================================================
-- schema.sql — E.1D: Agent session, turn, tool calls, prompt templates
-- ============================================================

-- ------------------------------------------------------------
-- AgentSession — overwrite (B.2); fixed/current metadata only
-- ------------------------------------------------------------
CREATE TABLE AgentSession (
    session_id INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    started_at TEXT    NOT NULL
);

-- ------------------------------------------------------------
-- PromptTemplateVersion — append-only; historical turns must link to the
-- exact text used, never today's (§2.5). Surrogate PK (C.2).
-- ------------------------------------------------------------
CREATE TABLE PromptTemplateVersion (
    prompt_template_version_id INTEGER PRIMARY KEY,
    template_id                 INTEGER NOT NULL,   -- groups versions of "the same" template
    version_no                   INTEGER NOT NULL CHECK (version_no >= 1),
    template_text                 TEXT    NOT NULL,
    edited_at                     TEXT    NOT NULL
);

CREATE UNIQUE INDEX ux_prompttemplateversion_natural_key
    ON PromptTemplateVersion (template_id, version_no);   -- natural key, retained per C.1

-- ------------------------------------------------------------
-- Turn — append-only, immutable once written (B.2). Surrogate PK (C.2).
-- A9: assistant_message nullable — a turn can exist without a completed reply.
-- A11: one assistant message per turn (no retries/regenerations modelled).
-- ------------------------------------------------------------
CREATE TABLE Turn (

    turn_id                       INTEGER PRIMARY KEY,

    session_id                    INTEGER NOT NULL REFERENCES AgentSession(session_id) ON DELETE CASCADE,

    turn_seq                      INTEGER NOT NULL CHECK (turn_seq >= 1),

    occurred_at                   TEXT    NOT NULL,

    user_message                  TEXT    NOT NULL,

    assistant_message              TEXT,               -- NULL means "generation failed / never completed" (A9)

    prompt_template_version_id    INTEGER REFERENCES PromptTemplateVersion(prompt_template_version_id)

                                   ON DELETE RESTRICT,

                                   -- NULL means "no template involved" (e.g. failed before template selection);

                                   -- RESTRICT: a template version must never be deletable while turns still cite it —

                                   -- deleting it would erase §2.5's "link to the exact text used" guarantee

    model_name                    TEXT,               -- NULL alongside a NULL assistant_message

    temperature                   REAL                -- NULL alongside a NULL assistant_message — no model call happened to set one

);

CREATE UNIQUE INDEX ux_turn_natural_key
    ON Turn (session_id, turn_seq);                    -- natural key, retained per C.1

-- ------------------------------------------------------------
-- ToolCall — append-only, immutable record of a call and its result.
-- Self-referencing FK for arbitrary-depth nesting (§2.5).
-- ------------------------------------------------------------
CREATE TABLE ToolCall (
    tool_call_id    INTEGER PRIMARY KEY,
    turn_id         INTEGER NOT NULL REFERENCES Turn(turn_id) ON DELETE CASCADE,
    parent_call_id  INTEGER REFERENCES ToolCall(tool_call_id) ON DELETE CASCADE,
                    -- NULL means "top-level call, not nested under another" (A10: sits under exactly one turn)
    tool_name       TEXT    NOT NULL,
    arguments_json  TEXT    NOT NULL CHECK (json_valid(arguments_json)),   -- E.4: JSON, guarded
    result_summary  TEXT,               -- NULL means "no result yet / call errored before producing one"
    latency_ms      INTEGER NOT NULL CHECK (latency_ms >= 0),
    errored         INTEGER NOT NULL CHECK (errored IN (0,1)),

    -- a call can't be its own parent
    CHECK (parent_call_id IS NULL OR parent_call_id != tool_call_id)
    -- deeper cycles (A → B → A) aren't declaratively preventable in SQLite —
    -- would need a recursive CTE check or trigger; noted in E.2, not built
    -- by default since nothing in the brief suggests the generator would
    -- ever produce one
);

-- ============================================================
-- schema.sql — E.1E: Pricing, judging, recommendation
-- ============================================================

-- ------------------------------------------------------------
-- ModelPricePeriod — validity intervals (B.2): "a price change must never
-- alter last quarter's reported costs" (§2.5).
-- Surrogate PK (C.2).
-- ------------------------------------------------------------
CREATE TABLE ModelPricePeriod (
    model_price_period_id INTEGER PRIMARY KEY,
    model_name            TEXT NOT NULL,
    valid_from            TEXT NOT NULL,
    valid_to              TEXT,
    input_rate            REAL NOT NULL CHECK (input_rate >= 0),
    output_rate           REAL NOT NULL CHECK (output_rate >= 0),
    cached_input_rate     REAL NOT NULL CHECK (cached_input_rate >= 0),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
    -- Non-overlap of price periods for the same model is not declarative —
    -- same overlap-prevention pattern as CreatorTierPeriod's trigger in E.1F,
    -- not separately implemented here.
);

CREATE UNIQUE INDEX ux_modelpriceperiod_natural_key
    ON ModelPricePeriod (model_name, valid_from);


-- ------------------------------------------------------------
-- TurnUsage — append-only, token counts fixed once computed (B.2).
-- FD analysis in D.1: turn_id → everything, BCNF trivially.
-- ------------------------------------------------------------
CREATE TABLE TurnUsage (
    turn_id               INTEGER PRIMARY KEY
                          REFERENCES Turn(turn_id) ON DELETE CASCADE,
    model_price_period_id INTEGER NOT NULL
                          REFERENCES ModelPricePeriod(model_price_period_id)
                          ON DELETE RESTRICT,
    input_tokens          INTEGER NOT NULL CHECK (input_tokens >= 0),
    output_tokens         INTEGER NOT NULL CHECK (output_tokens >= 0),
    cached_tokens         INTEGER NOT NULL CHECK (cached_tokens >= 0)
);


-- ------------------------------------------------------------
-- JudgeScore — append-only, one immutable judgment per turn (A11).
-- Most turns are never judged, so this table is sparse.
-- ------------------------------------------------------------
CREATE TABLE JudgeScore (
    turn_id      INTEGER PRIMARY KEY
                 REFERENCES Turn(turn_id) ON DELETE CASCADE,
    helpfulness  INTEGER NOT NULL CHECK (helpfulness BETWEEN 1 AND 5),
    groundedness INTEGER NOT NULL CHECK (groundedness BETWEEN 1 AND 5),
    safety       INTEGER NOT NULL CHECK (safety BETWEEN 1 AND 5)
);


-- ------------------------------------------------------------
-- UserRating — overwrite (A14): only the latest thumbs rating is kept.
-- Sparse like JudgeScore — a turn does not need to have a rating.
-- ------------------------------------------------------------
CREATE TABLE UserRating (
    turn_id INTEGER PRIMARY KEY
                 REFERENCES Turn(turn_id) ON DELETE CASCADE,
    thumbs  TEXT NOT NULL CHECK (thumbs IN ('up', 'down'))
);


-- ------------------------------------------------------------
-- Recommendation — append-only, immutable fact: this clip, this
-- position, this turn (B.2).
-- Candidate keys from D.1:
--   recommendation_id
--   (turn_id, position)
-- ------------------------------------------------------------
CREATE TABLE Recommendation (
    recommendation_id INTEGER PRIMARY KEY,
    turn_id           INTEGER NOT NULL
                      REFERENCES Turn(turn_id) ON DELETE CASCADE,
    position          INTEGER NOT NULL CHECK (position >= 1),
    video_id          INTEGER NOT NULL
                      REFERENCES Video(video_id) ON DELETE RESTRICT,
    UNIQUE (turn_id, position)
);

-- ============================================================
-- schema.sql — E.1F: Required triggers and integrity checks
-- ============================================================

-- ------------------------------------------------------------
-- REQUIRED: Block must break any existing follow in both directions (§2.3).
-- A block starts active (unblocked_at IS NULL), so inserting an active
-- block ends any currently active follow between the two users.
-- ------------------------------------------------------------
CREATE TRIGGER trg_block_ends_follows
AFTER INSERT ON Block
BEGIN
    UPDATE Follow
    SET ended_at = NEW.blocked_at,
        ended_reason = 'block'
    WHERE ended_at IS NULL
      AND (
            (follower_id = NEW.blocker_id AND followee_id = NEW.blocked_id)
         OR (follower_id = NEW.blocked_id AND followee_id = NEW.blocker_id)
          );
END;


-- ------------------------------------------------------------
-- BONUS: Prevent overlapping creator-tier validity periods.
-- The same interval-overlap pattern could be adapted to the other
-- temporal relations, but only one trigger is required here.
-- ------------------------------------------------------------
CREATE TRIGGER trg_creatortierperiod_no_overlap
BEFORE INSERT ON CreatorTierPeriod
WHEN EXISTS (
    SELECT 1
    FROM CreatorTierPeriod
    WHERE creator_id = NEW.creator_id
      AND valid_from <
          COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
      AND COALESCE(valid_to, '9999-12-31T23:59:59Z') >
          NEW.valid_from
)
BEGIN
    SELECT RAISE(
        ABORT,
        'CreatorTierPeriod: overlapping validity interval for this creator'
    );
END;


-- ------------------------------------------------------------
-- DELETION GRACE PERIOD / VISIBILITY
--
-- SQLite has no row-level security. Therefore pending-deletion
-- accounts are hidden through consumer-facing views such as
-- v_public_profile rather than through a trigger or base-table
-- constraint.
--
-- This means a direct SELECT from AppUser can still see such rows.
-- The visibility rule is therefore enforced by the consumer-facing
-- view/query layer, not by the schema itself.
-- ------------------------------------------------------------