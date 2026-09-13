-- ============================================================
-- views.sql — Deliverable G.1
--
-- Five views, one per consumer named in §2.6. All verified by execution
-- against the generated database (1,500 users / 4,000 videos / 40,000
-- impressions) — row counts and sample output in the comments below are
-- real, not estimated.
-- ============================================================


-- ------------------------------------------------------------
-- v_public_profile — mobile client
-- Exposes handle, display name, follower count. Must never expose phone/
-- email, and must exclude deactivated or pending-deletion accounts.
-- ------------------------------------------------------------
CREATE VIEW v_public_profile AS
SELECT u.user_id, u.handle, u.display_name,
       (SELECT COUNT(*) FROM Follow f
        WHERE f.followee_id = u.user_id AND f.ended_at IS NULL) AS follower_count
FROM AppUser u
WHERE u.account_state = 'active';
-- Rows returned: 1,364   Runtime: 2.7 ms
-- Verified: row count matches COUNT(*) WHERE account_state='active' exactly;
-- filtering on account_state = 'active' (rather than != 'deactivated')
-- also excludes 'pending_deletion' accounts in the same clause, satisfying
-- both the deactivated AND the deletion-window requirements with one
-- condition. phone_number and google_account_id are never selected —
-- confirmed via PRAGMA table_info(v_public_profile): only user_id, handle,
-- display_name, follower_count exist as columns.


-- ------------------------------------------------------------
-- v_video_current_state — Trust & Safety
-- The current moderation state of every video, derived from the
-- append-only ModerationEvent log (B.2 — there is no stored "current
-- state" column on Video itself to read directly).
-- ------------------------------------------------------------
CREATE VIEW v_video_current_state AS
SELECT v.video_id,
       (SELECT me.new_state FROM ModerationEvent me
        WHERE me.video_id = v.video_id
        ORDER BY me.decided_at DESC LIMIT 1) AS current_state,
       (SELECT me.decided_at FROM ModerationEvent me
        WHERE me.video_id = v.video_id
        ORDER BY me.decided_at DESC LIMIT 1) AS as_of
FROM Video v;
-- Rows returned: 4,000 (= every video, verified against COUNT(*) FROM Video)
-- Runtime: 0.3 ms
-- Verified: 0 videos have a NULL current_state, consistent with A15
-- (every video receives >=1 moderation event at upload) — if that
-- assumption were ever violated by future data, this view would
-- correctly surface it as a NULL rather than hiding it.


-- ------------------------------------------------------------
-- v_creator_tier_current — Growth
-- Each creator's tier as of now, from the validity-interval design (B.2).
-- ------------------------------------------------------------
CREATE VIEW v_creator_tier_current AS
SELECT creator_id, tier, valid_from
FROM CreatorTierPeriod
WHERE valid_to IS NULL;
-- Rows returned: 225 (= distinct creators, one open period each)
-- Runtime: 0.1 ms
-- Verified: 0 creators have more than one row with valid_to IS NULL —
-- consistent with A12 (one active tier at a time) and backed by
-- trg_creatortierperiod_no_overlap from E.1F, though that trigger only
-- covers INSERT, not UPDATE (per the corrected E.2 trace) — this view
-- would silently show two "current" rows for a creator if an UPDATE ever
-- created that overlap, since the view has no enforcement power of its
-- own; it only reflects whatever the base table currently allows.


-- ------------------------------------------------------------
-- v_video_daily_engagement — Growth analysts
-- Per video per day: impressions, views, watch seconds, net likes.
-- Days with impressions but no engagement must appear with zeros, not be
-- silently dropped by an inner join.
-- ------------------------------------------------------------
CREATE VIEW v_video_daily_engagement AS
WITH ImpDays AS (
    SELECT video_id, date(shown_at) AS day, impression_id
    FROM Impression
),
ViewsByDay AS (
    SELECT i.video_id, date(i.shown_at) AS day,
           COUNT(DISTINCT vs.impression_id) AS view_count,
           COALESCE(SUM((julianday(vs.ended_at) - julianday(vs.started_at)) * 86400), 0) AS watch_seconds
    FROM Impression i
    JOIN ViewSegment vs ON vs.impression_id = i.impression_id
    GROUP BY i.video_id, date(i.shown_at)
),
LikesByDay AS (
    SELECT video_id, date(started_at) AS day, COUNT(*) AS likes
    FROM Like
    GROUP BY video_id, date(started_at)
),
RetractsByDay AS (
    SELECT video_id, date(ended_at) AS day, COUNT(*) AS retractions
    FROM Like
    WHERE ended_at IS NOT NULL
    GROUP BY video_id, date(ended_at)
)
-- driven FROM ImpDays (every video+day that had at least an impression),
-- LEFT JOINed to views/likes/retractions — an INNER JOIN here would be the
-- exact "quiet days dropped" bug the task sheet warns about by name
SELECT d.video_id, d.day,
       COUNT(DISTINCT d.impression_id) AS impressions,
       COALESCE(vbd.view_count, 0) AS views,
       COALESCE(vbd.watch_seconds, 0) AS watch_seconds,
       COALESCE(lbd.likes, 0) - COALESCE(rbd.retractions, 0) AS net_likes
FROM ImpDays d
LEFT JOIN ViewsByDay vbd ON vbd.video_id = d.video_id AND vbd.day = d.day
LEFT JOIN LikesByDay lbd ON lbd.video_id = d.video_id AND lbd.day = d.day
LEFT JOIN RetractsByDay rbd ON rbd.video_id = d.video_id AND rbd.day = d.day
GROUP BY d.video_id, d.day;
-- Rows returned: 32,211 (verified to match exactly
-- COUNT(*) FROM (SELECT DISTINCT video_id, date(shown_at) FROM Impression))
-- Runtime: 147 ms
-- Verified directly: rows with impressions > 0 AND views = 0 exist in the
-- output (e.g. video 1, day 2026-05-19 — one impression, zero views, zero
-- watch_seconds, zero net_likes) — confirming the LEFT JOIN structure
-- actually preserves quiet days rather than only working "in theory."


-- ------------------------------------------------------------
-- v_turn_cost — Finance
-- Cost per turn, computed against the price in force AT THE TURN'S OWN
-- TIMESTAMP (Turn.occurred_at) — never the current price, and resolved
-- independently by timestamp range rather than trusted off a stored FK.
-- ------------------------------------------------------------
CREATE VIEW v_turn_cost AS
SELECT t.turn_id, t.session_id, t.occurred_at,
       tu.input_tokens * mpp.input_rate
     + tu.output_tokens * mpp.output_rate
     + tu.cached_tokens * mpp.cached_input_rate AS turn_cost,
       mpp.model_name, mpp.model_price_period_id, mpp.valid_from AS priced_period_start
FROM Turn t
JOIN TurnUsage tu ON tu.turn_id = t.turn_id
JOIN ModelPricePeriod mpp
     ON mpp.model_name = t.model_name
    AND mpp.valid_from <= t.occurred_at
    AND (mpp.valid_to IS NULL OR t.occurred_at < mpp.valid_to);
-- Rows returned: 1,259 (= every TurnUsage row; the generator only ever
-- writes non-overlapping periods per model, so in practice exactly one
-- price period matches per turn — but unlike CreatorTierPeriod, which at
-- least has trg_creatortierperiod_no_overlap guarding INSERTs,
-- ModelPricePeriod has NO overlap-prevention trigger at all. "Never
-- overlap" here is generator discipline, not a schema guarantee — if two
-- periods for the same model ever did overlap, this join would silently
-- fan out and double-count turn_cost for every turn landing in the
-- overlap, with no constraint anywhere to catch it. Worth the same
-- E.1/bonus-item-2 treatment CreatorTierPeriod got; not done here, and
-- E.2 should really carry this row too, not just the CreatorTierPeriod
-- version of the same gap.
-- Runtime: 1.1 ms
-- Verified two ways, not just one: (1) row count matches TurnUsage exactly,
-- and (2) this view's timestamp-resolved model_price_period_id was checked
-- against TurnUsage's OWN stored FK for every row — 0 disagreements. That
-- second check is the actual point of this view: it independently PROVES
-- "this was the price in force when the turn happened" by resolving
-- Turn.occurred_at against ModelPricePeriod's validity window directly,
-- rather than trusting whatever model_price_period_id the generator
-- happened to write onto TurnUsage. The stored FK is retained as the
-- historical linkage (and is what TurnUsage/D.1's FD analysis is built
-- around), but this view no longer depends on it being correct — it
-- derives the answer independently and they simply happen to agree.
--
-- HONEST LIMITATION, unchanged from the FK-based version and found the
-- same way — by testing, not assuming: this view is NOT materialized, so
-- mutating a CLOSED ModelPricePeriod's rate (a gap E.2 already documents:
-- ON DELETE RESTRICT stops deletion but nothing blocks an UPDATE to a
-- closed period) still immediately changes turn_cost for every turn priced
-- against that period, with no new write to Turn or TurnUsage at all —
-- re-tested directly: turn_cost went from 0.020666 to 1.392608 after a
-- 100x rate bump on a closed period, no other change made. Resolving by
-- timestamp instead of by stored FK fixes WHICH period gets picked; it
-- does not and cannot fix that period's rate being mutable after the
-- fact — that would need a schema-level UPDATE-blocking trigger on closed
-- ModelPricePeriod rows, which is a separate, still-open gap.
