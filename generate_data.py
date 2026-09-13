#!/usr/bin/env python3
"""
generate_data.py — Deliverable E.3

Populates a ScrollSense schema.sql database with synthetic, plausibly-
distributed data. Seeded by roll number for reproducibility; no two
submissions should carry the same data (per Task Sheet 0.3).

Usage:
    python generate_data.py [path/to/scrollsense.db]

Requires schema.sql to have already been applied to an empty database:
    sqlite3 scrollsense.db < schema.sql
    python generate_data.py scrollsense.db
"""

import sqlite3
import random
import sys
import json
from datetime import datetime, timedelta

# ---- parameters (Assignment 2 will change only this block) ----
SEED = "DA24B043"      # <-- REPLACE with your actual roll number before submitting
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 1                # A2: set to 50 for stress-test volumes
# -----------------------------------------------------------------

N_USERS = int(N_USERS * SCALE)
N_VIDEOS = int(N_VIDEOS * SCALE)
N_IMPRESSIONS = int(N_IMPRESSIONS * SCALE)
N_AGENT_SESSIONS = int(N_AGENT_SESSIONS * SCALE)

random.seed(SEED)

DB_PATH = sys.argv[1] if len(sys.argv) > 1 else "scrollsense.db"

EPOCH_START = datetime(2024, 1, 1)
EPOCH_END   = datetime(2026, 9, 1)
TOTAL_SECONDS = int((EPOCH_END - EPOCH_START).total_seconds())


# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def random_ts(start: datetime = EPOCH_START, end: datetime = EPOCH_END) -> datetime:
    span = int((end - start).total_seconds())
    return start + timedelta(seconds=random.randint(0, span))


def random_ts_after(after: datetime, end: datetime = EPOCH_END) -> datetime:
    """
    A timestamp STRICTLY after `after` (e.g. a user's created_at, a video's
    uploaded_at, or a prior event on the same row that a CHECK requires this
    one to exceed). If the window has collapsed (after >= end, which only
    happens for accounts/videos created right at EPOCH_END), extends a few
    seconds past `after` regardless of `end` rather than returning `after`
    itself — several CHECK constraints require a strict '>', not '>=', and
    silently satisfying that only in the common case would reintroduce a
    rare-but-real constraint violation.
    """
    if after >= end:
        return after + timedelta(seconds=random.randint(1, 30))
    span = int((end - after).total_seconds())
    return after + timedelta(seconds=random.randint(1, max(span, 1)))


def random_ts_daily_rhythm(start: datetime = EPOCH_START, end: datetime = EPOCH_END) -> datetime:
    """
    Activity follows a daily rhythm: weighted toward evening hours (18:00-23:00
    local-equivalent), sparse overnight (02:00-06:00). Approximated with a
    triangular-ish weighting over a 24h cycle rather than true seasonality.
    """
    day = random_ts(start, end).date()
    hour_weights = (
        [1, 1, 1, 1, 2, 3] +      # 00-05: quiet
        [4, 5, 6, 6, 5, 5] +      # 06-11: morning ramp
        [6, 7, 6, 5, 5, 6] +      # 12-17: afternoon
        [8, 10, 12, 12, 10, 6]    # 18-23: evening peak
    )
    hour = random.choices(range(24), weights=hour_weights, k=1)[0]
    minute = random.randint(0, 59)
    second = random.randint(0, 59)
    return datetime(day.year, day.month, day.day, hour, minute, second)


def random_ts_daily_rhythm_after(after: datetime, end: datetime = EPOCH_END) -> datetime:
    """Same evening-weighted daily rhythm as random_ts_daily_rhythm, but
    constrained to occur strictly after `after` (e.g. activity must come
    after the acting user's account was created)."""
    candidate = random_ts_daily_rhythm(after, end)
    if candidate < after:
        candidate = after
    return candidate


def power_law_int(low: int, high: int, alpha: float = 2.0) -> int:
    """Rough power-law-ish sample via inverse transform on a Pareto-like curve."""
    u = random.random()
    val = low * (1 - u) ** (-1 / alpha)
    return int(min(val, high))


def right_skewed_ms(min_ms: int, typical_ms: int, max_ms: int) -> int:
    """Log-normal-ish right-skewed duration in ms."""
    mu = 0
    sigma = 0.8
    factor = random.lognormvariate(mu, sigma)
    val = int(typical_ms * factor)
    return max(min_ms, min(val, max_ms))


def new_id_gen(start: int = 1):
    n = start
    while True:
        yield n
        n += 1


# ---------------------------------------------------------------
# Generation
# ---------------------------------------------------------------

def main():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON;")
    cur = conn.cursor()

    # Whole load in one transaction — SQLite auto-commits (and fsyncs) per
    # statement otherwise; 300k+ individual commits would dwarf everything
    # else in this assignment. executemany() inside one BEGIN/COMMIT instead.
    cur.execute("BEGIN;")

    try:
        user_ids, user_created = generate_users(cur)
        category_ids         = generate_categories(cur)
        generate_interests(cur, user_ids, category_ids, user_created)
        generate_account_status_events(cur, user_ids, user_created)
        generate_handle_change_events(cur, user_ids, user_created)

        creator_ids          = generate_creator_tier_periods(cur, user_ids, user_created)

        classifier_version_ids = generate_classifier_versions(cur)
        video_ids, audio_track_ids, video_uploaded = generate_videos_and_audio(
            cur, creator_ids, user_created
        )
        hashtag_ids           = generate_hashtags_and_links(cur, video_ids)
        generate_moderation_events(cur, video_ids, user_ids, classifier_version_ids, video_uploaded)

        generate_social_graph(cur, user_ids, user_created)

        prompt_template_version_ids = generate_prompt_templates(cur)
        model_price_period_ids       = generate_model_price_periods(cur)

        session_ids, turn_ids, turn_models, turn_occurred = generate_agent_sessions_and_turns(
            cur, user_ids, prompt_template_version_ids, user_created
        )
        generate_tool_calls(cur, turn_ids)
        generate_turn_usage(cur, turn_ids, turn_models, turn_occurred, model_price_period_ids)
        generate_judge_and_ratings(cur, turn_ids)
        recommendation_ids = generate_recommendations(cur, turn_ids, video_ids)

        generate_impressions_and_engagement(
            cur, user_ids, video_ids, recommendation_ids, user_created, video_uploaded
        )

        cur.execute("COMMIT;")
        print(f"Loaded successfully into {DB_PATH} (seed={SEED}, scale={SCALE})")

    except Exception:
        cur.execute("ROLLBACK;")
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------
# E.1A — AppUser, interests, account status
# ---------------------------------------------------------------

def generate_users(cur):
    ids = new_id_gen(1)
    rows = []
    handle_pool = set()

    for _ in range(N_USERS):
        uid = next(ids)
        auth_method = random.choices(["phone", "google"], weights=[6, 4])[0]
        phone = f"+91{random.randint(6000000000, 9999999999)}" if auth_method == "phone" else None
        google_acct = f"g_{uid}_{random.randint(1000,9999)}" if auth_method == "google" else None

        # ensure case-insensitive uniqueness among active accounts
        while True:
            base = f"user{uid}_{random.choice(['x','y','z','q'])}{random.randint(10,999)}"
            key = base.lower()
            if key not in handle_pool:
                handle_pool.add(key)
                break
        handle = base

        created = random_ts()
        account_state = random.choices(
            ["active", "deactivated", "pending_deletion"], weights=[92, 5, 3]
        )[0]
        deletion_requested_at = (
            iso(random_ts(created, EPOCH_END)) if account_state == "pending_deletion" else None
        )

        rows.append((
            uid, auth_method, phone, google_acct, handle,
            f"Display {uid}", account_state, deletion_requested_at, iso(created)
        ))

    cur.executemany(
        """INSERT INTO AppUser
           (user_id, auth_method, phone_number, google_account_id, handle,
            display_name, account_state, deletion_requested_at, created_at)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        rows
    )
    user_ids = [r[0] for r in rows]
    # created_at, parsed back to datetime, keyed by user_id — every later
    # generator that produces activity FOR a user reads this map instead of
    # drawing an independent random_ts(), so no user can be shown as acting
    # before their account existed.
    user_created = {r[0]: datetime.strptime(r[8], "%Y-%m-%dT%H:%M:%SZ") for r in rows}
    return user_ids, user_created


def generate_categories(cur):
    names = [
        "Comedy", "Dance", "Cooking", "Fitness", "Gaming", "Music", "Pets",
        "Fashion", "Travel", "DIY", "Sports", "Education", "Finance", "Beauty"
    ]
    rows = [(i + 1, name) for i, name in enumerate(names)]
    cur.executemany("INSERT INTO Category (category_id, name) VALUES (?,?)", rows)
    return [r[0] for r in rows]


def generate_interests(cur, user_ids, category_ids, user_created):
    declared_rows, inferred_rows, suppression_rows = [], [], []
    all_weeks = [EPOCH_START + timedelta(weeks=w) for w in range(0, 130, 1)]

    for uid in user_ids:
        created = user_created[uid]

        # each user declares 1-4 interests at signup — declared_at is
        # signup itself, so it IS created_at, not an independent draw
        for cid in random.sample(category_ids, k=random.randint(1, 4)):
            declared_rows.append((uid, cid, iso(created)))

        # weekly inferred interests: only weeks on/after the user existed
        eligible_weeks = [wk for wk in all_weeks if wk >= created] or [created]
        for cid in random.sample(category_ids, k=random.randint(1, 3)):
            k = min(random.randint(1, 6), len(eligible_weeks))
            for wk in random.sample(eligible_weeks, k=k):
                score = round(random.betavariate(2, 5), 3)  # right-skewed toward low confidence
                inferred_rows.append((uid, cid, wk.date().isoformat(), score))

        # ~8% of users suppress an inferred interest at some point
        if random.random() < 0.08:
            cid = random.choice(category_ids)
            sup_at = random_ts_after(created)
            unsup_at = None
            if random.random() < 0.4:  # some later un-suppress (A13)
                unsup_at = iso(random_ts_after(sup_at))
            suppression_rows.append((uid, cid, iso(sup_at), unsup_at))

    cur.executemany(
        "INSERT INTO UserDeclaredInterest (user_id, category_id, declared_at) VALUES (?,?,?)",
        declared_rows
    )
    cur.executemany(
        "INSERT INTO InferredInterest (user_id, category_id, as_of_week, score) VALUES (?,?,?,?)",
        list(set(inferred_rows))  # dedupe accidental (user,cat,week) collisions
    )
    cur.executemany(
        "INSERT INTO InterestSuppression (user_id, category_id, suppressed_at, unsuppressed_at) VALUES (?,?,?,?)",
        suppression_rows
    )


def generate_account_status_events(cur, user_ids, user_created):
    rows = []
    for uid in user_ids:
        # initial state begins when the account is created, not at EPOCH_START
        rows.append((uid, iso(user_created[uid]), "active"))
    cur.executemany(
        "INSERT INTO AccountStatusEvent (user_id, changed_at, new_state) VALUES (?,?,?)",
        rows
    )


def generate_handle_change_events(cur, user_ids, user_created):
    rows = []
    for uid in user_ids:
        if random.random() < 0.1:  # 10% of users have changed their handle
            n_changes = random.choices([1, 2], weights=[8, 2])[0]  # respects "<=2x/year" spirit
            cursor_time = user_created[uid]
            for _ in range(n_changes):
                cursor_time = random_ts_after(cursor_time)
                rows.append((
                    uid, iso(cursor_time),
                    f"old_{uid}_{random.randint(1,999)}",
                    f"new_{uid}_{random.randint(1,999)}"
                ))
    cur.executemany(
        "INSERT INTO HandleChangeEvent (user_id, changed_at, old_handle, new_handle) VALUES (?,?,?,?)",
        rows
    )


# ---------------------------------------------------------------
# E.1B — Creator tier, video/content, moderation
# ---------------------------------------------------------------

def generate_creator_tier_periods(cur, user_ids, user_created):
    # ~15% of users are creators
    creator_ids = random.sample(user_ids, k=int(N_USERS * 0.15))
    tiers = ["standard", "bronze", "silver", "gold", "platinum"]  # generator's own domain, not a schema CHECK
    rows = []

    for cid in creator_ids:
        # a creator's first tier period can't start before their account did
        cursor_time = user_created[cid]
        n_periods = random.choices([1, 2, 3], weights=[6, 3, 1])[0]
        for i in range(n_periods):
            valid_from = cursor_time
            is_last = (i == n_periods - 1)
            if is_last:
                valid_to = None
            else:
                valid_to = valid_from + timedelta(days=random.randint(30, 240))
            tier = random.choices(tiers, weights=[40, 25, 20, 10, 5])[0]
            rows.append((cid, iso(valid_from), iso(valid_to) if valid_to else None, tier))
            if valid_to is None:
                break
            cursor_time = valid_to  # next period starts exactly when previous ends (non-overlapping)

    cur.executemany(
        "INSERT INTO CreatorTierPeriod (creator_id, valid_from, valid_to, tier) VALUES (?,?,?,?)",
        rows
    )
    return creator_ids


def generate_classifier_versions(cur):
    rows = [
        (1, "moderation-classifier-v1", iso(EPOCH_START)),
        (2, "moderation-classifier-v2", iso(EPOCH_START + timedelta(days=180))),
        (3, "moderation-classifier-v3", iso(EPOCH_START + timedelta(days=420))),
    ]
    cur.executemany(
        "INSERT INTO ClassifierVersion (classifier_version_id, name, released_at) VALUES (?,?,?)",
        rows
    )
    return [r[0] for r in rows]


def generate_videos_and_audio(cur, creator_ids, user_created):
    video_ids = list(range(1, N_VIDEOS + 1))
    track_ids = list(range(1, N_VIDEOS // 4 + 1))  # far fewer tracks than videos — 50k clips/track is the brief's example

    # Videos first (audio_track_id NULL for now; both FKs are DEFERRABLE so
    # order within the transaction doesn't matter, but doing it in two clean
    # passes keeps this generator readable)
    video_rows = []
    video_uploaded = {}   # video_id -> datetime, so moderation events can anchor to it
    for vid in video_ids:
        owner = random.choice(creator_ids)
        duration_ms = right_skewed_ms(20_000, 35_000, 90_000)
        # a video can't be uploaded before its owner's account existed
        uploaded_at = random_ts_after(user_created[owner])
        video_uploaded[vid] = uploaded_at
        video_rows.append((vid, owner, duration_ms, f"Caption for video {vid} #tag{vid % 50}", None, iso(uploaded_at)))

    cur.executemany(
        """INSERT INTO Video (video_id, owner_id, duration_ms, caption, audio_track_id, uploaded_at)
           VALUES (?,?,?,?,?,?)""",
        video_rows
    )

    # AudioTrack: most are catalogue (licensed, no origin); a minority originate from a video
    track_rows = []
    origin_candidates = random.sample(video_ids, k=min(len(track_ids) // 3, len(video_ids)))
    for i, tid in enumerate(track_ids):
        if i < len(origin_candidates):
            origin = origin_candidates[i]
            is_licensed = 0
        else:
            origin = None
            is_licensed = 1
        track_rows.append((tid, origin, is_licensed))

    cur.executemany(
        "INSERT INTO AudioTrack (track_id, origin_video_id, is_licensed) VALUES (?,?,?)",
        track_rows
    )

    # Now assign tracks to videos (power-law: a few trending tracks used heavily)
    weights = [power_law_int(1, 200, alpha=1.5) for _ in track_ids]
    updates = []
    for vid in video_ids:
        if random.random() < 0.7:  # 70% of videos use some track; rest have none
            tid = random.choices(track_ids, weights=weights, k=1)[0]
            updates.append((tid, vid))

    cur.executemany("UPDATE Video SET audio_track_id = ? WHERE video_id = ?", updates)

    return video_ids, track_ids, video_uploaded


def generate_hashtags_and_links(cur, video_ids):
    tags = [
        "catdog", "fyp", "cooking", "travelvlog", "comedy", "fitness",
        "dance", "petsofinsta", "diy", "study", "gamingclips", "music"
    ]
    hashtag_ids = list(range(1, len(tags) + 1))
    cur.executemany(
        "INSERT INTO Hashtag (hashtag_id, text) VALUES (?,?)",
        list(zip(hashtag_ids, tags))
    )

    links = []
    for vid in video_ids:
        for hid in random.sample(hashtag_ids, k=random.randint(0, 3)):
            links.append((vid, hid))
    cur.executemany(
        "INSERT INTO VideoHashtag (video_id, hashtag_id) VALUES (?,?)",
        list(set(links))
    )
    return hashtag_ids


def generate_moderation_events(cur, video_ids, user_ids, classifier_version_ids, video_uploaded):
    rows = []
    reviewer_pool = random.sample(user_ids, k=min(200, len(user_ids)))  # small pool of T&S reviewers

    for vid in video_ids:
        # A15: every video gets >=1 event, first one automated at upload.
        # The classifier fires a few seconds after the actual Video.uploaded_at
        # (never before it, and never drawn independently of it).
        upload_time = video_uploaded[vid] + timedelta(seconds=random.randint(1, 30))
        first_state = random.choices(
            ["pending", "live"], weights=[3, 7]
        )[0]
        rows.append((
            vid, iso(upload_time), first_state, "automated",
            None, random.choice(classifier_version_ids)
        ))

        # some videos get further transitions
        n_extra = random.choices([0, 1, 2, 3], weights=[70, 15, 10, 5])[0]
        cursor_time = upload_time
        for _ in range(n_extra):
            cursor_time = cursor_time + timedelta(hours=random.randint(1, 800))
            new_state = random.choice(["live", "age_restricted", "demoted", "taken_down"])
            if random.random() < 0.6:
                rows.append((vid, iso(cursor_time), new_state, "automated",
                             None, random.choice(classifier_version_ids)))
            else:
                rows.append((vid, iso(cursor_time), new_state, "human",
                             random.choice(reviewer_pool), None))

    cur.executemany(
        """INSERT INTO ModerationEvent
           (video_id, decided_at, new_state, decided_by_kind, reviewer_id, classifier_version_id)
           VALUES (?,?,?,?,?,?)""",
        rows
    )


# ---------------------------------------------------------------
# E.1C — Follow/Block/Mute + impressions/watch/engagement
# ---------------------------------------------------------------

def generate_social_graph(cur, user_ids, user_created):
    follow_rows, block_rows, mute_rows = [], [], []

    # power-law follower counts: a few users get lots of followers
    followee_weights = [power_law_int(1, 3000, alpha=1.3) for _ in user_ids]

    n_follows = int(N_USERS * 4)  # avg ~4 follows/user
    seen_pairs = set()
    for _ in range(n_follows):
        follower = random.choice(user_ids)
        followee = random.choices(user_ids, weights=followee_weights, k=1)[0]
        if follower == followee or (follower, followee) in seen_pairs:
            continue
        seen_pairs.add((follower, followee))
        # a follow can't start before EITHER party's account existed
        earliest = max(user_created[follower], user_created[followee])
        started = random_ts_after(earliest)
        if random.random() < 0.15:
            ended = random_ts_after(started)
            follow_rows.append((follower, followee, iso(started), iso(ended), "unfollowed"))
        else:
            follow_rows.append((follower, followee, iso(started), None, None))

    # trg_block_ends_follows sets Follow.ended_at = the block's blocked_at for
    # any matching active follow — if blocked_at lands before that follow's
    # started_at, the trigger's own UPDATE violates Follow's ended_at >
    # started_at CHECK. So a block's timestamp must also come after the
    # latest started_at of any existing follow between the same pair.
    latest_follow_started = {}
    for (f_follower, f_followee, f_started_iso, _, _) in follow_rows:
        pair = tuple(sorted((f_follower, f_followee)))
        prev = latest_follow_started.get(pair)
        if prev is None or f_started_iso > prev:
            latest_follow_started[pair] = f_started_iso

    for _ in range(int(N_USERS * 0.02)):  # blocks are rarer than follows
        blocker = random.choice(user_ids)
        blocked = random.choice(user_ids)
        if blocker == blocked:
            continue
        earliest = max(user_created[blocker], user_created[blocked])
        pair = tuple(sorted((blocker, blocked)))
        pair_follow_started = latest_follow_started.get(pair)
        if pair_follow_started is not None:
            pair_follow_dt = datetime.strptime(pair_follow_started, "%Y-%m-%dT%H:%M:%SZ")
            earliest = max(earliest, pair_follow_dt)
        blocked_at = random_ts_after(earliest)
        unblocked_at = iso(random_ts_after(blocked_at)) if random.random() < 0.2 else None
        block_rows.append((blocker, blocked, iso(blocked_at), unblocked_at))

    for _ in range(int(N_USERS * 0.05)):
        muter = random.choice(user_ids)
        muted = random.choice(user_ids)
        if muter == muted:
            continue
        earliest = max(user_created[muter], user_created[muted])
        muted_at = random_ts_after(earliest)
        unmuted_at = iso(random_ts_after(muted_at)) if random.random() < 0.3 else None
        mute_rows.append((muter, muted, iso(muted_at), unmuted_at))

    cur.executemany(
        "INSERT INTO Follow (follower_id, followee_id, started_at, ended_at, ended_reason) VALUES (?,?,?,?,?)",
        follow_rows
    )
    # Block rows inserted one at a time so trg_block_ends_follows fires per-row
    # and can see each block's effect before the next insert (executemany withturn_id, session_id, turn_seq, user_message,
    # AFTER INSERT triggers is fine in SQLite, but doing it explicitly here
    # documents that the trigger dependency is understood, not incidental)
    cur.executemany(
        "INSERT INTO Block (blocker_id, blocked_id, blocked_at, unblocked_at) VALUES (?,?,?,?)",
        block_rows
    )
    cur.executemany(
        "INSERT INTO Mute (muter_id, muted_id, muted_at, unmuted_at) VALUES (?,?,?,?)",
        mute_rows
    )


def generate_impressions_and_engagement(cur, user_ids, video_ids, recommendation_ids,
                                         user_created, video_uploaded):
    impression_rows = []
    segment_rows = []
    like_rows = []
    signal_rows = []

    # power-law: some videos get shown far more than others
    video_weights = [power_law_int(1, 5000, alpha=1.4) for _ in video_ids]

    impression_id = 1
    # cache which recommendations exist to occasionally attribute an impression to one
    rec_sample = recommendation_ids if recommendation_ids else []

    # recommendation_id -> video_id, so an impression attributed to a
    # recommendation always shows the SAME video that recommendation
    # actually recommended (a single query here beats one per impression)
    rec_video = {}
    if rec_sample:
        for rec_id, v_id in cur.execute(
            "SELECT recommendation_id, video_id FROM Recommendation"
        ).fetchall():
            rec_video[rec_id] = v_id

    seen_impression_keys = set()

    for _ in range(N_IMPRESSIONS):
        uid = random.choice(user_ids)
        source_rec = random.choice(rec_sample) if rec_sample and random.random() < 0.03 else None

        if source_rec is not None:
            # the impression must be of the same clip the recommendation recommended
            vid = rec_video[source_rec]
        else:
            vid = random.choices(video_ids, weights=video_weights, k=1)[0]

        # an impression can't happen before the viewing user's account
        # existed, or before the video itself was uploaded
        earliest = max(user_created[uid], video_uploaded[vid])
        shown_at = random_ts_daily_rhythm_after(earliest)
        # Impression's natural key is (user_id, video_id, shown_at) with
        # second-granularity timestamps; at higher N_IMPRESSIONS a birthday-
        # paradox collision on the same (user, video) pair in the same
        # second becomes real, not hypothetical. Nudge forward by a second
        # until the key is free rather than losing the row to a UNIQUE
        # constraint failure mid-transaction.
        key = (uid, vid, iso(shown_at))
        while key in seen_impression_keys:
            shown_at = shown_at + timedelta(seconds=1)
            key = (uid, vid, iso(shown_at))
        seen_impression_keys.add(key)
        feed_position = random.randint(0, 50)
        ranking_model_version = random.choice(["ranker-v1", "ranker-v2", "ranker-v3"])

        impression_rows.append((
            impression_id, uid, vid, iso(shown_at), feed_position,
            ranking_model_version, source_rec
        ))

        # funnel: most impressions never become a view (§2.4 — the funnel leaks at every stage)
        if random.random() < 0.35:  # 35% cross the 300ms view bar
            n_segments = random.choices([1, 2, 3], weights=[85, 12, 3])[0]  # loops are rare
            seg_cursor = shown_at
            for seg_seq in range(1, n_segments + 1):
                seg_start = seg_cursor
                # watch duration right-skewed; can exceed clip duration cumulatively
                seg_ms = right_skewed_ms(300, 4000, 90_000)
                seg_end = seg_start + timedelta(milliseconds=seg_ms)
                reached_end = 1 if random.random() < 0.3 else 0
                segment_rows.append((
                    impression_id, seg_seq, iso(seg_start), iso(seg_end), reached_end
                ))
                seg_cursor = seg_end

            # of the viewed impressions, most produce no explicit signal (§2.4)
            if random.random() < 0.08:
                like_start = shown_at + timedelta(seconds=random.randint(1, 30))
                like_rows.append((uid, vid, iso(like_start), None))  # retractions handled separately below

            if random.random() < 0.04:
                sig_type = random.choices(
                    ["save", "share", "comment", "follow_from_feed", "not_interested", "report"],
                    weights=[30, 25, 15, 10, 15, 5]
                )[0]
                destination = (
                    random.choice(["whatsapp", "instagram", "copied_link"])
                    if sig_type == "share" else None
                )
                signal_ts = shown_at + timedelta(seconds=random.randint(1, 60))
                signal_rows.append((uid, vid, sig_type, iso(signal_ts), destination))

        impression_id += 1

    cur.executemany(
        """INSERT INTO Impression
           (impression_id, user_id, video_id, shown_at, feed_position,
            ranking_model_version, source_recommendation_id)
           VALUES (?,?,?,?,?,?,?)""",
        impression_rows
    )
    cur.executemany(
        """INSERT INTO ViewSegment (impression_id, segment_seq, started_at, ended_at, reached_end)
           VALUES (?,?,?,?,?)""",
        segment_rows
    )

    # Deduplicate likes on (user_id, video_id, started_at) collisions from random ts clashes
    like_rows = list({(u, v, s): (u, v, s, e) for (u, v, s, e) in like_rows}.values())

    # A small fraction of likes get retracted within 60s (F4's target pattern) —
    # split into "quick retraction" and "normal/never retracted" groups
    final_like_rows = []
    retract_signal_rows = []
    for (u, v, s, _) in like_rows:
        started_dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
        if random.random() < 0.06:  # ~6% retracted quickly — feeds F4 directly
            ended_dt = started_dt + timedelta(seconds=random.randint(1, 59))
            final_like_rows.append((u, v, s, iso(ended_dt)))
            retract_signal_rows.append((u, v, "like_retract", iso(ended_dt), None))
        elif random.random() < 0.15:  # some retracted later, not within 60s
            ended_dt = started_dt + timedelta(minutes=random.randint(2, 10000))
            final_like_rows.append((u, v, s, iso(ended_dt)))
            retract_signal_rows.append((u, v, "like_retract", iso(ended_dt), None))
        else:
            final_like_rows.append((u, v, s, None))

    cur.executemany(
        "INSERT INTO Like (user_id, video_id, started_at, ended_at) VALUES (?,?,?,?)",
        final_like_rows
    )

    signal_rows.extend(retract_signal_rows)
    # dedupe on PK (user_id, video_id, signal_type, occurred_at)
    signal_rows = list({(u, v, t, ts): (u, v, t, ts, d) for (u, v, t, ts, d) in signal_rows}.values())
    cur.executemany(
        "INSERT INTO EngagementSignal (user_id, video_id, signal_type, occurred_at, destination) VALUES (?,?,?,?,?)",
        signal_rows
    )


# ---------------------------------------------------------------
# E.1D — Agent session, turn, tool calls, prompt templates
# ---------------------------------------------------------------

def generate_prompt_templates(cur):
    rows = []
    ptv_id = 1
    for template_id in range(1, 4):  # 3 template families (explainer, search, etc.)
        n_versions = random.randint(3, 8)  # "edited several times a week" -> many versions over the period
        edited = EPOCH_START
        for version_no in range(1, n_versions + 1):
            edited = edited + timedelta(days=random.randint(3, 20))
            rows.append((
                ptv_id, template_id, version_no,
                f"Template {template_id} v{version_no}: {{context}} -> explanation text...",
                iso(edited)
            ))
            ptv_id += 1
    cur.executemany(
        """INSERT INTO PromptTemplateVersion
           (prompt_template_version_id, template_id, version_no, template_text, edited_at)
           VALUES (?,?,?,?,?)""",
        rows
    )
    return [r[0] for r in rows]


def generate_model_price_periods(cur):
    models = ["gpt-4o-mini", "llama-3.1-70b", "internal-ft-v1"]
    rows = []
    mpp_id = 1
    for model in models:
        cursor_time = EPOCH_START
        n_periods = random.randint(2, 4)
        for i in range(n_periods):
            valid_from = cursor_time
            is_last = (i == n_periods - 1)
            valid_to = None if is_last else valid_from + timedelta(days=random.randint(60, 300))
            input_rate = round(random.uniform(0.00005, 0.001), 6)
            output_rate = round(input_rate * random.uniform(2, 4), 6)
            cached_rate = round(input_rate * random.uniform(0.3, 0.6), 6)
            rows.append((
                mpp_id, model, iso(valid_from),
                iso(valid_to) if valid_to else None,
                input_rate, output_rate, cached_rate
            ))
            mpp_id += 1
            if valid_to is None:
                break
            cursor_time = valid_to

    cur.executemany(
        """INSERT INTO ModelPricePeriod
           (model_price_period_id, model_name, valid_from, valid_to, input_rate, output_rate, cached_input_rate)
           VALUES (?,?,?,?,?,?,?)""",
        rows
    )
    return [r[0] for r in rows]


def generate_agent_sessions_and_turns(cur, user_ids, prompt_template_version_ids, user_created):
    session_rows = []
    turn_rows = []
    session_ids = list(range(1, N_AGENT_SESSIONS + 1))
    turn_id = 1
    turn_ids = []
    turn_models = {}
    turn_occurred = {}   # turn_id -> datetime, needed to price against the
                          # ACTUAL price period in force at that instant,
                          # not just any valid period for the model

    for sid in session_ids:
        uid = random.choice(user_ids)
        # a session can't start before its user's account existed
        started = random_ts_daily_rhythm_after(user_created[uid])
        session_rows.append((sid, uid, iso(started)))

        n_turns = random.choices([1, 2, 3, 4, 5], weights=[40, 25, 15, 12, 8])[0]
        cursor_time = started
        for seq in range(1, n_turns + 1):
            cursor_time = cursor_time + timedelta(seconds=random.randint(5, 120))
            failed = random.random() < 0.03  # A9: rare generation failures
            assistant_msg = None if failed else f"Here are some clips about your query..."
            ptv = None if failed and random.random() < 0.5 else random.choice(prompt_template_version_ids)
            model_name = None if (failed and ptv is None) else random.choice(
                ["gpt-4o-mini", "llama-3.1-70b", "internal-ft-v1"]
            )
            temperature = None if model_name is None else round(random.uniform(0.2, 1.0), 2)

            turn_rows.append((
                turn_id, sid, seq, iso(cursor_time), f"User asks about clip {turn_id}...",
                assistant_msg, ptv, model_name, temperature
            ))
            turn_models[turn_id] = model_name
            turn_occurred[turn_id] = cursor_time
            turn_ids.append(turn_id)
            turn_id += 1

    cur.executemany(
        "INSERT INTO AgentSession (session_id, user_id, started_at) VALUES (?,?,?)",
        session_rows
    )
    cur.executemany(
        """INSERT INTO Turn
           (turn_id, session_id, turn_seq, occurred_at, user_message, assistant_message,
            prompt_template_version_id, model_name, temperature)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        turn_rows
    )
    return session_ids, turn_ids, turn_models, turn_occurred


def generate_tool_calls(cur, turn_ids):
    rows = []
    tool_call_id = 1
    tool_names = ["search_videos", "get_user_history", "fetch_trending_audio"]

    for tid in turn_ids:
        if random.random() < 0.6:  # not every turn issues tool calls
            n_calls = random.randint(1, 3)
            for _ in range(n_calls):
                parent_id = None
                errored = 1 if random.random() < 0.05 else 0
                args = json.dumps({"query": "example", "filters": {}})
                latency = random.randint(20, 1500)
                result = None if errored else "5 results found"
                rows.append((
                    tool_call_id, tid, parent_id, random.choice(tool_names),
                    args, result, latency, errored
                ))
                this_call = tool_call_id
                tool_call_id += 1

                # occasional nested sub-call
                if random.random() < 0.15:
                    sub_errored = 1 if random.random() < 0.05 else 0
                    rows.append((
                        tool_call_id, tid, this_call, "search_videos",
                        json.dumps({"query": "nested"}), None if sub_errored else "2 results",
                        random.randint(10, 500), sub_errored
                    ))
                    tool_call_id += 1

    cur.executemany(
        """INSERT INTO ToolCall
           (tool_call_id, turn_id, parent_call_id, tool_name, arguments_json,
            result_summary, latency_ms, errored)
           VALUES (?,?,?,?,?,?,?,?)""",
        rows
    )


def generate_turn_usage(cur, turn_ids, turn_models, turn_occurred, model_price_period_ids):
    rows = []

    # group available price periods by model name, WITH their validity
    # window, so a turn's usage is priced against the period that was
    # ACTUALLY in force at the turn's own occurred_at — not just any valid
    # period for the model. Fetching valid_from/valid_to as datetimes once
    # up front avoids a per-turn query across up to N_AGENT_SESSIONS*5 turns.
    price_rows = cur.execute(
        "SELECT model_price_period_id, model_name, valid_from, valid_to FROM ModelPricePeriod"
    ).fetchall()
    periods_by_model = {}
    for pid, model_name, vf, vt in price_rows:
        periods_by_model.setdefault(model_name, []).append((
            pid,
            datetime.strptime(vf, "%Y-%m-%dT%H:%M:%SZ"),
            datetime.strptime(vt, "%Y-%m-%dT%H:%M:%SZ") if vt else None
        ))

    for tid in turn_ids:
        model_name = turn_models[tid]
        # a turn with no model (failed before model selection, A9) can't be priced
        if model_name is not None and random.random() < 0.97:
            occurred = turn_occurred[tid]
            candidates = [
                pid for (pid, vf, vt) in periods_by_model[model_name]
                if vf <= occurred and (vt is None or occurred < vt)
            ]
            if not candidates:
                # no period for this model was open at the turn's own
                # timestamp (can happen at the very edges of the price
                # history) — fall back to the earliest period for the
                # model rather than silently dropping the turn's usage row
                candidates = [periods_by_model[model_name][0][0]]
            mpp = candidates[0]  # periods for a model never overlap, so at
                                  # most one candidate should exist anyway
            input_tok = power_law_int(50, 4000, alpha=1.8)
            output_tok = power_law_int(10, 2000, alpha=1.8)
            cached_tok = random.randint(0, input_tok // 2)
            rows.append((tid, mpp, input_tok, output_tok, cached_tok))

    cur.executemany(
        """INSERT INTO TurnUsage
           (turn_id, model_price_period_id, input_tokens, output_tokens, cached_tokens)
           VALUES (?,?,?,?,?)""",
        rows
    )


def generate_judge_and_ratings(cur, turn_ids):
    judge_rows, rating_rows = [], []
    for tid in turn_ids:
        if random.random() < 0.10:  # most turns are never judged (§2.5)
            judge_rows.append((
                tid,
                random.randint(1, 5), random.randint(1, 5), random.randint(1, 5)
            ))
        if random.random() < 0.05:  # very few ever rated by a user
            rating_rows.append((tid, random.choices(["up", "down"], weights=[7, 3])[0]))

    cur.executemany(
        "INSERT INTO JudgeScore (turn_id, helpfulness, groundedness, safety) VALUES (?,?,?,?)",
        judge_rows
    )
    cur.executemany(
        "INSERT INTO UserRating (turn_id, thumbs) VALUES (?,?)",
        rating_rows
    )


def generate_recommendations(cur, turn_ids, video_ids):
    rows = []
    rec_id = 1
    rec_ids = []
    for tid in turn_ids:
        if random.random() < 0.4:  # only some turns are conversational-search turns that return a shelf
            n_recs = random.randint(1, 8)
            chosen_videos = random.sample(video_ids, k=min(n_recs, len(video_ids)))
            for pos, vid in enumerate(chosen_videos, start=1):
                rows.append((rec_id, tid, pos, vid))
                rec_ids.append(rec_id)
                rec_id += 1

    cur.executemany(
        "INSERT INTO Recommendation (recommendation_id, turn_id, position, video_id) VALUES (?,?,?,?)",
        rows
    )
    return rec_ids


if __name__ == "__main__":
    main()
