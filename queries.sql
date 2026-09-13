-- ============================================================
-- queries.sql — Deliverable F
--
-- All queries verified by execution against a generated database
-- (1,500 users / 4,000 videos / 40,000 impressions / 600 sessions,
-- seed=2100007). Row counts, sample rows, and runtimes below are
-- taken directly from that run — not estimated or invented.
--
-- Design note applying to every query below: all timestamp columns
-- are stored as ISO-8601 TEXT with a literal 'T' and trailing 'Z'
-- (e.g. '2026-03-03T14:32:07Z'). SQLite's datetime()/date() functions
-- return a DIFFERENT text format (space-separated, no 'Z'). Comparing
-- our columns directly against datetime()'s output with string <=/>=
-- silently breaks precisely when two timestamps share the same
-- calendar day (the 'T' vs ' ' character at position 10 decides the
-- comparison before the actual time-of-day is ever read — full
-- write-up of this in the E.1/F prose). Every date comparison and
-- arithmetic operation below therefore goes through julianday(),
-- which parses both formats to the same numeric representation and
-- compares/arithmetics correctly regardless of format.
-- ============================================================


-- ============================================================
-- Tier 1 — core SQL
-- ============================================================

-- F1 · Top 10 audio tracks by number of distinct videos in the last 7 days.
-- Intent: "last 7 days" is relative to the most recent upload in the
-- dataset (there's no "now" in a static generated database), via julianday
-- arithmetic rather than string comparison against datetime()'s output.
-- Expected shape: one row per track, ranked by distinct video count.
SELECT at.track_id, at.is_licensed, COUNT(DISTINCT v.video_id) AS distinct_videos
FROM AudioTrack at
JOIN Video v ON v.audio_track_id = at.track_id
WHERE julianday(v.uploaded_at) >= (SELECT julianday(MAX(uploaded_at)) - 7 FROM Video)
GROUP BY at.track_id
ORDER BY distinct_videos DESC
LIMIT 10;
-- Rows returned: 10   Runtime: 1.6 ms
-- Sample: (195, 0, 8), (485, 1, 5), (936, 1, 3), (273, 0, 3), (906, 1, 2)
-- Reading: the top track this week is a catalogue (non-original) track —
-- consistent with the brief's framing that a handful of trending sounds
-- get used far more than any one creator's original audio.


-- F2 · Watch hours and mean completion rate per creator, live clips only.
-- Intent: EVERY creator must appear, including those with zero live clips
-- and those never watched — the query is deliberately driven FROM the set
-- of all creators (distinct Video.owner_id), never from LiveVideo directly,
-- because starting from LiveVideo would silently drop any creator whose
-- clips are all pending/taken_down/etc. "Live" is resolved per-video as
-- the chronologically latest ModerationEvent.new_state (append-only log,
-- per B.2 — there is no stored "current state" column to read directly).
-- Expected shape: one row per creator; row count = COUNT(DISTINCT owner_id).
WITH AllCreators AS (
    -- Video.owner_id, NOT CreatorTierPeriod.creator_id — matches the
    -- decision locked in Deliverable C.2. Nothing in the schema guarantees
    -- every video owner has a CreatorTierPeriod row (no FK ties them
    -- together), so sourcing this from CreatorTierPeriod would risk
    -- silently dropping a creator with live clips but no tier row yet —
    -- exactly the anti-pattern the brief warns against by name. At this
    -- dataset's scale the two sets happen to coincide exactly (225 = 225,
    -- zero set difference either direction), but that's a property of
    -- this generator run, not something the schema enforces.
    SELECT DISTINCT owner_id AS creator_id FROM Video
),
LiveVideo AS (
    SELECT v.video_id, v.owner_id
    FROM Video v
    WHERE (
        SELECT me.new_state FROM ModerationEvent me
        WHERE me.video_id = v.video_id
        ORDER BY me.decided_at DESC LIMIT 1
    ) = 'live'
),
ImpressionCompletion AS (
    SELECT i.impression_id, i.video_id,
           COALESCE(SUM(
               (julianday(vs.ended_at) - julianday(vs.started_at)) * 86400000
           ), 0) AS watch_ms,
           MAX(vs.reached_end) AS completed
    FROM Impression i
    LEFT JOIN ViewSegment vs ON vs.impression_id = i.impression_id
    GROUP BY i.impression_id, i.video_id
),
VideoAgg AS (
    SELECT video_id,
           SUM(watch_ms) AS total_watch_ms,
           AVG(COALESCE(completed, 0)) AS completion_rate
    FROM ImpressionCompletion
    GROUP BY video_id
),
CreatorVideoAgg AS (
    SELECT lv.owner_id, lv.video_id,
           COALESCE(va.total_watch_ms, 0) AS total_watch_ms,
           COALESCE(va.completion_rate, 0) AS completion_rate
    FROM LiveVideo lv
    LEFT JOIN VideoAgg va ON va.video_id = lv.video_id
)
SELECT ac.creator_id,
       ROUND(COALESCE(SUM(cva.total_watch_ms), 0) / 3600000.0, 3) AS watch_hours,
       ROUND(COALESCE(AVG(cva.completion_rate), 0), 4) AS mean_completion_rate
FROM AllCreators ac
LEFT JOIN CreatorVideoAgg cva ON cva.owner_id = ac.creator_id
GROUP BY ac.creator_id
ORDER BY watch_hours DESC;
-- Rows returned: 225 (= COUNT(DISTINCT owner_id) in Video, verified directly)
--   Runtime: 53.7 ms
-- Sample: (726, 0.559, 0.065), (1191, 0.453, 0.0601), (714, 0.279, 0.1186)
-- Reading: watch hours are sharply top-heavy — the top creator holds roughly
-- 5x the watch time of the 5th-ranked creator — consistent with the
-- power-law popularity weighting used in the generator.
-- Note on "mean completion rate": this averages completion rate PER VIDEO,
-- not per impression — a creator with one heavily-watched video and one
-- never-watched video gets equal weight for both in the average, matching
-- "mean completion rate" read as a property of the creator's catalogue
-- rather than a play-count-weighted rate. A different, equally defensible
-- reading (weighted by impressions) would need a different formula; this
-- is a stated interpretation, not the only one.


-- F3 · Videos with no audio track — NOT IN vs NOT EXISTS.
SELECT video_id FROM Video
WHERE audio_track_id NOT IN (SELECT track_id FROM AudioTrack);
-- Rows returned: 0   Runtime: 1.4 ms

SELECT v.video_id FROM Video v
WHERE NOT EXISTS (SELECT 1 FROM AudioTrack at WHERE at.track_id = v.audio_track_id);
-- Rows returned: 1229   Runtime: 1.5 ms
-- Explanation of the difference: AudioTrack.track_id is never NULL (it's
-- the PK), so the NULL causing this isn't in the subquery — it's in the
-- OUTER column, Video.audio_track_id, which is NULL for every video with
-- no track (1,229 of them, per A5). For those rows, SQL's three-valued
-- logic evaluates `NULL NOT IN (list)` to NULL, not TRUE — so the WHERE
-- clause silently drops every single one of them, and NOT IN returns 0.
-- NOT EXISTS never performs an equality comparison against audio_track_id
-- directly; for a NULL audio_track_id, the correlated subquery's condition
-- `at.track_id = v.audio_track_id` is NULL for every row (never TRUE), so
-- EXISTS is FALSE and NOT EXISTS is TRUE — correctly returning all 1,229
-- videos with no track. NOT IN is unsafe here specifically because the
-- comparison target (not the list) can be NULL; NOT EXISTS has no such
-- failure mode because it never does a direct equality test against NULL.


-- F4 · Users who liked and retracted within 60 seconds of the same clip.
SELECT user_id, video_id, started_at, ended_at
FROM Like
WHERE ended_at IS NOT NULL
  AND (julianday(ended_at) - julianday(started_at)) * 86400 <= 60;
-- Rows returned: 70   Runtime: 0.65 ms
-- Sample: (282, 3573, '2026-07-24T05:02:53Z', '2026-07-24T05:02:55Z')
-- Reading: several retractions happen within 2-3 seconds of the like
-- itself — consistent with an accidental double-tap pattern rather than a
-- considered "actually I don't like this" reversal.


-- F5 · Videos whose caption carries a given hashtag, case-insensitive,
-- tolerant of surrounding punctuation/whitespace.
-- Intent: normalise the caption by turning '#' and common punctuation
-- into spaces, lower-casing, and padding with spaces at both ends, then
-- match the target hashtag as a space-delimited "word" via LIKE, with
-- instr() as an explicit belt-and-braces re-check of the same condition
-- (both must agree the normalised hashtag is present) — satisfies the
-- task's requirement to build this from lower()/trim()/replace()/instr()/
-- LIKE specifically, not just an equivalent using a subset of them.
SELECT video_id, caption
FROM (
    SELECT video_id, caption,
        ' ' ||
        lower(
          replace(replace(replace(replace(replace(replace(replace(
            caption,
          '#', ' '), '.', ' '), ',', ' '), '!', ' '), '?', ' '), char(9), ' '), char(10), ' ')
        )
        || ' ' AS norm_caption
    FROM Video
)
WHERE norm_caption LIKE '%' || ' ' || lower(trim(:target_hashtag, '# ')) || ' ' || '%'
  AND instr(norm_caption, ' ' || lower(trim(:target_hashtag, '# ')) || ' ') > 0;
-- Bind :target_hashtag = 'tag5' for this run.
-- Rows returned: 80   Runtime: 19.6 ms
-- Cross-checked: exactly matches COUNT(*) WHERE video_id % 50 = 5, which is
-- how the generator actually assigns #tagN — confirms no over- or under-match.
-- Answer to the required one-liner: LIKE was used, not GLOB — SQLite's LIKE
-- is case-insensitive for ASCII by default, but this query doesn't actually
-- rely on that behaviour, since lower() is called explicitly before the
-- comparison. For a caption written in Tamil, the answer does NOT change:
-- Tamil script has no case distinction at all, so lower() is a no-op on
-- Tamil text and the hashtag simply matches or doesn't based on the exact
-- characters present — no extra handling is needed OR gained here, unlike
-- the AppUser.handle NOCASE situation in E.1/E.2, which is a genuinely
-- different mechanism (a COLLATE index, not an explicit lower() call).


-- F6 · Users shown a creator's clips but never engaged, via a set operator;
-- then one signal roll-up shown with UNION and UNION ALL.
-- Bind :creator_id = 576 (the creator with the most videos in this dataset)
-- for this run.
SELECT i.user_id FROM Impression i
JOIN Video v ON v.video_id = i.video_id
WHERE v.owner_id = :creator_id
EXCEPT
SELECT es.user_id FROM EngagementSignal es
JOIN Video v ON v.video_id = es.video_id
WHERE v.owner_id = :creator_id
EXCEPT
SELECT l.user_id FROM Like l
JOIN Video v ON v.video_id = l.video_id
WHERE v.owner_id = :creator_id;
-- Rows returned: 196   Runtime: 11.6 ms
-- Reading: 196 distinct users saw this creator's clips and never liked,
-- saved, shared, commented, followed-from-feed, reported, or
-- not-interested'd any of them — the largest share of anyone who was ever
-- shown this creator's content, matching the brief's "funnel leaks at
-- every stage" framing.

SELECT user_id, video_id FROM EngagementSignal
UNION
SELECT user_id, video_id FROM Like;
-- Rows returned: 1625   Runtime: <1 ms

SELECT user_id, video_id FROM EngagementSignal
UNION ALL
SELECT user_id, video_id FROM Like;
-- Rows returned: 1890   Runtime: <1 ms
-- Explanation: UNION ALL keeps every row from both sources (1,890 total);
-- UNION additionally de-duplicates identical (user_id, video_id) pairs
-- appearing in BOTH EngagementSignal and Like, dropping 265 of them. This
-- makes sense: a user who both liked a clip AND, say, saved it produces one
-- row in each source table with the same (user_id, video_id) — UNION
-- collapses that pair to a single row, UNION ALL doesn't. For counting
-- "how many distinct (user, video) engagement pairs exist", UNION is
-- correct; for "how many engagement events happened", UNION ALL is.


-- F7 · Cost of each agent session last month, broken out by prompt
-- template version, restricted to sessions whose TOTAL cost exceeds a
-- threshold. Intent: "last month" = the 30 days ending at the most recent
-- session start in the dataset (again via julianday, not string
-- comparison). The threshold applies to the session as a whole — a
-- session must clear the bar on its total spend before its per-template
-- breakdown is shown at all; filtering per (session, template) group
-- instead would let a session with several small per-template slivers,
-- none individually over threshold but summing well past it, slip through
-- undercounted, or conversely show a lone big-spending template row from a
-- session whose total doesn't actually clear the bar. Threshold chosen:
-- $0.01 (arbitrary, parameterised via bound value).
WITH TurnCost AS (
    SELECT tu.turn_id, t.session_id, ptv.prompt_template_version_id,
           tu.input_tokens * mpp.input_rate
         + tu.output_tokens * mpp.output_rate
         + tu.cached_tokens * mpp.cached_input_rate AS turn_cost
    FROM TurnUsage tu
    JOIN Turn t ON t.turn_id = tu.turn_id
    JOIN ModelPricePeriod mpp ON mpp.model_price_period_id = tu.model_price_period_id
    LEFT JOIN PromptTemplateVersion ptv ON ptv.prompt_template_version_id = t.prompt_template_version_id
),
LastMonth AS (SELECT julianday(MAX(started_at)) - 30 AS cutoff FROM AgentSession),
SessionTotalCost AS (
    -- filter on the session's TOTAL cost first, independent of template
    SELECT s.session_id, SUM(tc.turn_cost) AS total_session_cost
    FROM AgentSession s
    JOIN TurnCost tc ON tc.session_id = s.session_id
    WHERE julianday(s.started_at) >= (SELECT cutoff FROM LastMonth)
    GROUP BY s.session_id
    HAVING SUM(tc.turn_cost) > :threshold
)
-- then, for exactly those qualifying sessions, break the cost out by template
SELECT s.session_id, stc.total_session_cost, tc.prompt_template_version_id,
       ROUND(SUM(tc.turn_cost), 6) AS session_cost_for_template
FROM SessionTotalCost stc
JOIN AgentSession s ON s.session_id = stc.session_id
JOIN TurnCost tc ON tc.session_id = s.session_id
GROUP BY s.session_id, tc.prompt_template_version_id
ORDER BY stc.total_session_cost DESC, session_cost_for_template DESC;
-- Bind :threshold = 0.01 for this run.
-- Rows returned: 159 (85 distinct qualifying sessions, each broken into
--   1-4 template rows)   Runtime: 3.6 ms
-- Sample: (127, 0.744098, 13, 0.368723), (127, 0.744098, 9, 0.275293),
--         (127, 0.744098, 10, 0.087707), (127, 0.744098, 7, 0.012375)
-- Verified: every row's total_session_cost > threshold (0 violations), and
-- for every session, its template-cost rows sum back exactly to
-- total_session_cost (0 mismatches) — checked directly, not assumed.
-- Reading: cost is priced against the historical model_price_period_id
-- stored on TurnUsage at generation time (§2.5's "never alter last
-- quarter's cost" guarantee), not against ModelPricePeriod's current rate
-- — this is the same mechanism v_turn_cost (Deliverable G) will expose.


-- F8 · Videos whose moderation state actually CHANGED more than twice,
-- with the full chronological sequence of transitions.
-- Intent: "state changed" means the state differs from the immediately
-- preceding event for that video — a run of repeated identical states
-- (e.g. 'live' logged three times in a row before finally moving to
-- 'demoted') is not three changes, it's one, regardless of how many
-- ModerationEvent rows exist. A video's very first ModerationEvent is
-- also NOT counted as a "change" here — there is no prior state for it
-- to change FROM, so it establishes the initial state rather than
-- transitioning into it. LAG(new_state) over each video's event history,
-- ordered by decided_at, exposes the previous state per row; only rows
-- with a genuine prior state that differs count.
-- Requires SQLite 3.44+ for ORDER BY inside group_concat (confirmed
-- running on 3.45.1 — sqlite_version() checked before writing this).
WITH StateWithPrev AS (
    SELECT video_id, decided_at, new_state,
           LAG(new_state) OVER (PARTITION BY video_id ORDER BY decided_at) AS prev_state
    FROM ModerationEvent
),
ActualChanges AS (
    SELECT video_id, decided_at, new_state
    FROM StateWithPrev
    WHERE prev_state IS NOT NULL
      AND new_state <> prev_state
)
SELECT video_id, COUNT(*) AS n_actual_changes,
       group_concat(new_state, ' -> ' ORDER BY decided_at) AS sequence
FROM ActualChanges
GROUP BY video_id
HAVING COUNT(*) > 2
ORDER BY n_actual_changes DESC;
-- Rows returned: 77   Runtime: 17.2 ms
-- Re-verified directly against video 3963's raw ModerationEvent history
-- (pending @05-11, demoted @06-03, taken_down @06-17, live @07-10 — 4 raw
-- events, all genuinely distinct from their predecessor): this query
-- correctly excludes the FIRST event (pending, no prior state to compare
-- against) and returns exactly 3 actual changes for that video —
-- (3963, 3, 'demoted -> taken_down -> live') — not 4. An earlier draft of
-- this query counted the first event as a "change" too (410 rows, 4-state
-- sequences including the initial state); this version is the one
-- actually reflected in the row count and samples below.
-- Sample: (3963, 3, 'demoted -> taken_down -> live'),
--         (3949, 3, 'demoted -> live -> age_restricted'),
--         (3948, 3, 'demoted -> age_restricted -> demoted')
-- Reading: video 3948's sequence ('demoted -> age_restricted -> demoted')
-- shows a video re-entering 'demoted' after leaving it — worth flagging to
-- Trust & Safety as either a legitimate re-review flow or a sign the
-- moderation pipeline is flip-flopping on some videos, since the brief
-- doesn't say state transitions are monotonic in either direction.


-- ============================================================
-- Tier 2 — window functions and recursion
-- ============================================================

-- F9 · Each user's longest streak of consecutive active days.
-- Intent: "active day" = at least one impression shown to the user that
-- calendar day. Classic gaps-and-islands: subtracting a per-user row
-- number (ordered by date) from the date's ordinal collapses each
-- consecutive run to a single constant group key.
WITH ActiveDays AS (
    SELECT DISTINCT user_id, date(shown_at) AS active_date
    FROM Impression
),
Numbered AS (
    SELECT user_id, active_date,
           julianday(active_date) - ROW_NUMBER() OVER (
               PARTITION BY user_id ORDER BY active_date
           ) AS grp
    FROM ActiveDays
),
Streaks AS (
    SELECT user_id, grp, COUNT(*) AS streak_len
    FROM Numbered
    GROUP BY user_id, grp
)
SELECT user_id, MAX(streak_len) AS longest_streak_days
FROM Streaks
GROUP BY user_id
ORDER BY longest_streak_days DESC;
-- Rows returned: 1500 (= every user who has ever had an impression;
--   ordered subset shown below)   Runtime: 70.1 ms
-- Top rows: (842, 14), (64, 13), (1347, 11), (860, 11), (230, 11)
-- Reading: the longest streak in this dataset is 14 consecutive days —
-- plausible given ~2.5 years of simulated activity and impressions
-- randomly distributed per user rather than clustered into real habitual
-- usage patterns (a real user base would likely show longer streaks from
-- daily-habit users than this synthetic, independently-sampled data does).


-- F10 · Rank creators by 7-day rolling watch time, week-over-week change.
-- Intent: "7 days" is explicitly CALENDAR days here, not "the 7 days on
-- which this creator had activity" (the task sheet flags these as
-- different queries — this is the one Growth actually asked for). RANGE
-- frames take numeric offsets only in SQLite, so ordering by
-- julianday(day) with RANGE BETWEEN 6 PRECEDING AND CURRENT ROW gives a
-- true trailing-7-calendar-day sum even across gap days with no activity,
-- since RANGE compares the actual julianday VALUE, not row position.
WITH DailyWatch AS (
    SELECT v.owner_id AS creator_id,
           date(i.shown_at) AS day,
           SUM((julianday(vs.ended_at) - julianday(vs.started_at)) * 86400) AS watch_seconds
    FROM ViewSegment vs
    JOIN Impression i ON i.impression_id = vs.impression_id
    JOIN Video v ON v.video_id = i.video_id
    GROUP BY v.owner_id, date(i.shown_at)
),
Rolling AS (
    SELECT creator_id, day,
           SUM(watch_seconds) OVER (
               PARTITION BY creator_id
               ORDER BY julianday(day)
               RANGE BETWEEN 6 PRECEDING AND CURRENT ROW
           ) AS rolling_7d_watch_seconds
    FROM DailyWatch
),
Latest AS (
    SELECT creator_id, MAX(day) AS latest_day
    FROM Rolling
    GROUP BY creator_id
)
SELECT r.creator_id, r.day AS as_of_day,
       ROUND(r.rolling_7d_watch_seconds, 1) AS rolling_7d_watch_seconds,
       ROUND(r.rolling_7d_watch_seconds - COALESCE(prior.rolling_7d_watch_seconds, 0), 1) AS week_over_week_change,
       RANK() OVER (ORDER BY r.rolling_7d_watch_seconds DESC) AS creator_rank
FROM Rolling r
JOIN Latest l ON l.creator_id = r.creator_id AND l.latest_day = r.day
LEFT JOIN Rolling prior
       ON prior.creator_id = r.creator_id
      AND prior.day = date(r.day, '-7 days')
ORDER BY creator_rank;
-- Rows returned: 225 (one per creator with any watch activity)   Runtime: 51.9 ms
-- Top rows: (1246, '2026-08-31', 799.0, 789.0, 1), (726, '2026-08-31', 490.0, 188.0, 2)
-- Reading: the #1 creator's week-over-week change (+789s) is almost their
-- entire rolling total, meaning nearly all of their watch time is brand
-- new this week rather than sustained — worth distinguishing "growing
-- fast" from "just had one viral day" before Growth acts on this ranking.
-- Note: week_over_week_change compares to the row EXACTLY 7 calendar days
-- earlier via a self-join on date(); if the creator had no activity on
-- that exact date, COALESCE(...,0) treats the prior baseline as zero —
-- this slightly overstates week-over-week growth for creators with sparse
-- posting schedules, a limitation worth stating rather than hiding.


-- F11 · Full nesting tree for a given agent session's tool calls, with depth.
-- Bind :session_id = 286 (the session with the most tool calls) for this run.
WITH RECURSIVE CallTree AS (
    SELECT tc.tool_call_id, tc.turn_id, tc.parent_call_id, tc.tool_name, tc.errored,
           0 AS depth
    FROM ToolCall tc
    JOIN Turn t ON t.turn_id = tc.turn_id
    WHERE t.session_id = :session_id AND tc.parent_call_id IS NULL

    UNION ALL

    SELECT child.tool_call_id, child.turn_id, child.parent_call_id, child.tool_name, child.errored,
           ct.depth + 1
    FROM ToolCall child
    JOIN CallTree ct ON child.parent_call_id = ct.tool_call_id
)
SELECT tool_call_id, turn_id, parent_call_id, depth, tool_name, errored
FROM CallTree
ORDER BY turn_id, depth, tool_call_id;
-- Rows returned: 14   Runtime: 1.5 ms
-- Sample: (857, 671, NULL, 0, 'search_videos', 0), (859, 671, 858, 1, 'search_videos', 0)
-- Reading: this session's deepest nesting is depth 1 (a top-level call with
-- one nested sub-call) — matches the generator's own 15% nesting
-- probability; a production dataset with genuinely recursive agent tool
-- use could show depth 2+ and this query needs no changes to handle it,
-- which is the point of using a recursive CTE here rather than a
-- fixed number of self-joins.


-- F12 · Sessions where the agent recommended a clip the user watched to
-- completion, reporting the clip's shelf position. This is the query the
-- task sheet calls "the spine of the whole design" — and it IS a direct
-- join, not a heuristic, specifically because B.3 decision #2 put an
-- explicit source_recommendation_id FK on Impression rather than inferring
-- provenance from timestamp proximity.
SELECT t.session_id, r.recommendation_id, r.turn_id, r.position, r.video_id,
       i.impression_id, i.user_id
FROM Recommendation r
JOIN Turn t ON t.turn_id = r.turn_id
JOIN Impression i ON i.source_recommendation_id = r.recommendation_id
JOIN ViewSegment vs ON vs.impression_id = i.impression_id
WHERE vs.reached_end = 1
GROUP BY t.session_id, r.recommendation_id, i.impression_id
ORDER BY r.position;
-- Rows returned: 146   Runtime: 21.1 ms
-- Sample (session_id, recommendation_id, turn_id, position, video_id, impression_id, user_id):
--   (5, 12, 10, 1, 3333, 8699, 110), (9, 36, 18, 1, 3327, 33333, 583),
--   (14, 54, 27, 1, 3077, 10204, 583)
-- Reading: every sampled row here has position = 1 — a mild indication
-- that position-1 recommendations get completed more often than lower
-- shelf positions in this dataset, though confirming that as a real effect
-- (rather than an artifact of how few impressions get attributed to a
-- recommendation at all, per F6's funnel-leak framing) would need a
-- dedicated completion-rate-by-position query, which this one doesn't do.


-- F13 · Turns where the LLM judge scored above 4 but the user thumbs-downed.
SELECT js.turn_id, js.helpfulness, js.groundedness, js.safety, ur.thumbs
FROM JudgeScore js
JOIN UserRating ur ON ur.turn_id = js.turn_id
WHERE js.helpfulness > 4 AND ur.thumbs = 'down';
-- Rows returned: 0   Runtime: 0.5 ms
-- Reading: genuinely empty at this dataset's scale, not a query bug —
-- verified by checking the unfiltered join: only 5 turns in the whole
-- dataset have BOTH a JudgeScore AND a UserRating at all (115 judged out
-- of 1,326 turns, 74 rated — both deliberately sparse per §2.5's "most
-- turns are never judged, very few are ever rated"), and none of those 5
-- happen to have helpfulness > 4 with thumbs='down'. At the assignment's
-- full default scale (2,000 sessions vs this run's 600) the overlap would
-- be proportionally larger and this pattern would very likely appear.
-- Why this disagreement set matters commercially: it's the clearest
-- signal available that the judge model and real users disagree about
-- quality on the SAME turn — every other quality signal (judge alone, user
-- rating alone) can be wrong without anyone noticing, but a turn the judge
-- calls excellent that a real user explicitly rejects is either (a) a
-- judge-model calibration bug worth fixing before trusting judge scores at
-- scale, or (b) evidence the judge is optimizing for something users don't
-- actually value (e.g. verbosity, hedging, a safety-cautious tone read as
-- unhelpful) — either finding directly changes how much Product should
-- trust the judge pipeline versus keep collecting real user ratings.
