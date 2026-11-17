# 01 — Normalization: Local Event Carpool Coordinator

This document walks the schema from the capstone plan through 1NF → 2NF → 3NF → BCNF, records the functional dependencies (FDs) behind each table, flags the places where the schema is **deliberately denormalized**, and ends with the final schema.

---

## 1. Why normalize

The app is write-heavy on small, related records (requests, approvals, ratings). Normalization keeps one fact in one place so that:

- changing a user's name, a zone's name or an event's date is a single-row update (no update anomaly),
- deleting the last ride for an event does not erase the event (no deletion anomaly),
- a zone or event can exist before any ride uses it (no insertion anomaly).

---

## 2. Starting point (UNF): the "ride board" view

If we had built the app from a single flat sheet, it would look like this:

| ride_id | event_name | event_date | event_category | driver_name | driver_email | zone_name | adjacent_zones | departure_time | seats | riders_requested | rider_status | ratings_given |
|---|---|---|---|---|---|---|---|---|---|---|---|---|

Problems:

| Problem | Where it shows up | Violates |
|---|---|---|
| Multi-valued cells | `adjacent_zones`, `riders_requested`, `rider_status`, `ratings_given` hold lists | 1NF |
| Event data repeated on every ride | `event_name`, `event_date`, `event_category` depend on the event, not the ride | 2NF |
| Driver data repeated on every ride | `driver_name`, `driver_email` depend on the driver | 3NF (transitive: ride → driver_id → driver_name) |
| Zone data repeated | `zone_name` depends on `zone_id` | 3NF |

Decomposing along those dependencies gives the eight tables in the plan: `users`, `zones`, `zone_adjacency`, `events`, `rides`, `ride_requests`, `ratings`, `notifications`.

---

## 3. Normal forms, briefly

- **1NF** — every cell holds one atomic value; every row is uniquely identifiable.
- **2NF** — 1NF, and no non-key column depends on only part of a composite key.
- **3NF** — 2NF, and no non-key column depends on another non-key column (no transitive dependencies).
- **BCNF** — for every non-trivial FD `X → Y`, `X` is a superkey.

Every table below uses a single-column surrogate primary key (`id`), so partial dependencies (2NF) cannot occur by construction. The interesting checks are 3NF/BCNF against the **other candidate keys** and the **business rules**.

---

## 4. Table-by-table analysis

### 4.1 `users (id, name, email, password_hash, avg_rating)`

**Candidate keys:** `id`, `email` (unique).

**FDs**
- `id → name, email, password_hash, avg_rating`
- `email → id, name, password_hash, avg_rating`

Both determinants (`id`, `email`) are candidate keys → **BCNF** for the stored attributes.

**Caveat — `avg_rating` is a derived column.** It equals `AVG(stars)` over `ratings` where `rated_id = users.id`. Storing it means a second source of truth. See §5.1.

---

### 4.2 `zones (id, name)`

**Candidate keys:** `id`, `name` (unique).

**FDs:** `id → name`, `name → id`. Both sides are keys → **BCNF**.

---

### 4.3 `zone_adjacency (zone_id, adjacent_zone_id)`

**Key:** composite `(zone_id, adjacent_zone_id)`. There are no non-key attributes, so there is nothing to depend partially or transitively → **BCNF** (all-key relation).

**Design rule (not a normal-form issue, but it matters):** adjacency is *symmetric*. If A is adjacent to B, B is adjacent to A. Two ways to model it:

1. **Store both directions** (A,B) and (B,A). Simple JOIN, slight redundancy, must insert pairs together. *Recommended for this project.*
2. Store one direction with `CHECK (zone_id < adjacent_zone_id)` and query with a `UNION`. No redundancy, slightly more complex query.

Add `CHECK (zone_id <> adjacent_zone_id)` so a zone isn't adjacent to itself.

---

### 4.4 `events (id, name, date, category, is_recurring)`

**Candidate key:** `id`.

**FDs:** `id → name, date, category, is_recurring`.

- `category` is a plain value from a small set (college fest / gym / market / exam / custom). It doesn't determine any other column, so there is **no transitive dependency** → **BCNF**.
- If categories later gain their own attributes (icon, colour), split to an `event_categories` lookup table. Not needed now.

**Gaps vs. the plan (see §6):** `location` is described in the feature list but missing from the schema; recurring clones have no link back to the event they were cloned from.

---

### 4.5 `rides (id, event_id, driver_id, zone_id, departure_time, total_seats, seats_available, cost_split, total_cost, status)`

**Candidate key:** `id`.

**FDs**
- `id → event_id, driver_id, zone_id, departure_time, total_seats, seats_available, cost_split, total_cost, status`
- Event details (`name`, `date`…) and driver details (`name`, `email`…) are **not** stored here; they are reached through `event_id` and `driver_id`. This is exactly what removes the transitive dependencies from the UNF table.

→ **3NF/BCNF** for the stored attributes.

**Two derived/conditional columns to be aware of:**
- `seats_available` = `total_seats − COUNT(approved requests)`. Derived, but kept on purpose (§5.2).
- `total_cost` only has meaning when `cost_split = true`. This is a *conditional* attribute, not a normal-form violation. Enforce it with a CHECK (§7). A rider's "your share" is `total_cost / (approved riders)` and is **computed at read time, not stored**.

---

### 4.6 `ride_requests (id, ride_id, rider_id, status)`

**Candidate keys:** `id`, and `(ride_id, rider_id)` — a rider should have at most one request per ride.

**FDs**
- `id → ride_id, rider_id, status`
- `(ride_id, rider_id) → id, status`

Both determinants are candidate keys → **BCNF**. The plan did not state the `(ride_id, rider_id)` uniqueness; without it, duplicate requests are possible and `seats_available` bookkeeping can drift. Add the constraint.

---

### 4.7 `ratings (id, ride_id, rater_id, rated_id, stars, comment)`

**Candidate keys:** `id`, and `(ride_id, rater_id, rated_id)` — one rating per person-pair per ride.

**FDs**
- `id → ride_id, rater_id, rated_id, stars, comment`
- `(ride_id, rater_id, rated_id) → id, stars, comment`

→ **BCNF**.

Why `rated_id` is *not* redundant: on a ride with several riders, `(ride_id, rater_id)` alone does not determine who is being rated (a driver rates each rider separately), so `rated_id` is a genuine part of the key.

Rules to enforce: `stars BETWEEN 1 AND 5`, `rater_id <> rated_id`. That both people were actually on the ride (and that the ride is `completed`) cannot be a CHECK — enforce in application code.

---

### 4.8 `notifications (id, user_id, message, is_read, created_at)`

**Candidate key:** `id`.

**FDs:** `id → user_id, message, is_read, created_at` → **BCNF**.

`message` is free text composed at write time, so it is atomic for our purposes (**1NF** holds). Trade-off: you can't easily query "all notifications about ride 42". If you need that later, add nullable `ride_id` (FK) rather than parsing `message`.

---

## 5. Deliberate denormalizations

### 5.1 `users.avg_rating`

| | |
|---|---|
| Normalized alternative | Don't store it; compute `AVG(stars) FROM ratings WHERE rated_id = ?` or expose a view. |
| Why keep it | Profile pages and ride lists show ratings constantly; avoiding an aggregate per row is cheaper and simpler for the UI. |
| Risk | Stale value if a rating is inserted/edited/deleted without updating it. |
| Mitigation | Recalculate inside the **same transaction** that inserts a rating (or use a DB trigger). Treat `ratings` as the source of truth. |

**Decision:** keep for the capstone, document it as a controlled denormalization, and recompute in the rating-insert transaction. Since you will be asked about it in a viva, say so explicitly: *"3NF would drop it; I kept it for read performance and keep it consistent transactionally."*

### 5.2 `rides.seats_available`

| | |
|---|---|
| Normalized alternative | `total_seats − COUNT(*) FROM ride_requests WHERE ride_id = ? AND status = 'approved'`. |
| Why keep it | The plan's anti-oversell logic is "check-then-update with `CHECK (seats_available >= 0)`". A stored counter lets the database itself reject an overbooking, even under concurrent approvals. A computed value cannot be protected by a CHECK. |
| Risk | Counter and approved-request count disagree. |
| Mitigation | Approve/cancel **always** runs in a transaction: `UPDATE rides SET seats_available = seats_available - 1 WHERE id = ? AND seats_available > 0` and the status change on `ride_requests` together. Check `affected rows = 1`. |

**Decision:** keep. This is the one denormalization that is functionally required.

### 5.3 `rides.cost_split` + `total_cost`

Not redundant, but `total_cost` is NULL when `cost_split = false`. Alternative is to drop `cost_split` and treat `total_cost IS NOT NULL` as the flag. Keeping the boolean is clearer to read and query; the CHECK in §7 keeps the two consistent.

---

## 6. Gaps and fixes found while normalizing

| # | Issue | Fix |
|---|---|---|
| 1 | `events.location` is in the feature list ("name, date, location, category") but missing from the schema. | Add `location VARCHAR`. If events should reuse zones, use `zone_id` FK instead. |
| 2 | Recurring clones have no link to the event they came from, so "this week's gym" vs "last week's gym" are unrelated rows. | Add nullable `parent_event_id` (self-referencing FK) pointing to the original recurring event. The cron job sets it on each clone. |
| 3 | `events.created_by` missing though "anyone can create an event". | Add `created_by` FK → `users.id`. |
| 4 | `ride_requests` allows duplicate `(ride_id, rider_id)`. | `UNIQUE (ride_id, rider_id)`. |
| 5 | `ratings` allows duplicates and self-ratings. | `UNIQUE (ride_id, rater_id, rated_id)`, `CHECK (rater_id <> rated_id)`. |
| 6 | Enumerated columns (`status`, `category`) have no stated domain. | `CHECK (status IN (...))` or native `ENUM`. |
| 7 | `departure_time` and `events.date` can disagree (ride departing days after the event). | Application rule: `departure_time` must fall on/before the event datetime. Not expressible as a single-table CHECK. |
| 8 | No `created_at` on rides/requests, which the 1-hour reminder cron and "ride history" views will want. | Add `created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`. |
| 9 | A driver could request a seat on their own ride. | Application-level check (`rider_id <> rides.driver_id`); not a single-table constraint. |
| 10 | Reminder cron needs to avoid sending the 1-hour notification twice. | Add `rides.reminder_sent BOOLEAN DEFAULT FALSE`. |

---

## 7. Final normalized schema

Written in generic SQL (works as-is on PostgreSQL; on MySQL replace `GENERATED ... AS IDENTITY` with `AUTO_INCREMENT`, and note CHECK constraints need MySQL 8.0.16+).

```sql
CREATE TABLE users (
  id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          VARCHAR(100) NOT NULL,
  email         VARCHAR(255) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  avg_rating    NUMERIC(3,2)           -- denormalized; see §5.1
    CHECK (avg_rating IS NULL OR avg_rating BETWEEN 1 AND 5)
);

CREATE TABLE zones (
  id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE zone_adjacency (
  zone_id          INT NOT NULL REFERENCES zones(id) ON DELETE CASCADE,
  adjacent_zone_id INT NOT NULL REFERENCES zones(id) ON DELETE CASCADE,
  PRIMARY KEY (zone_id, adjacent_zone_id),
  CHECK (zone_id <> adjacent_zone_id)
  -- insert both (A,B) and (B,A) so the symmetric relation is a plain JOIN
);

CREATE TABLE events (
  id              INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            VARCHAR(150) NOT NULL,
  event_date      TIMESTAMP    NOT NULL,
  location        VARCHAR(200) NOT NULL,
  category        VARCHAR(20)  NOT NULL
    CHECK (category IN ('college_fest','gym','market','exam','concert','custom')),
  is_recurring    BOOLEAN      NOT NULL DEFAULT FALSE,
  parent_event_id INT REFERENCES events(id) ON DELETE SET NULL, -- set on cron clones
  created_by      INT NOT NULL REFERENCES users(id)
);

CREATE TABLE rides (
  id              INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id        INT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  driver_id       INT NOT NULL REFERENCES users(id),
  zone_id         INT NOT NULL REFERENCES zones(id),
  departure_time  TIMESTAMP NOT NULL,
  total_seats     INT NOT NULL CHECK (total_seats > 0),
  seats_available INT NOT NULL,                 -- denormalized; see §5.2
  cost_split      BOOLEAN NOT NULL DEFAULT FALSE,
  total_cost      NUMERIC(8,2),
  status          VARCHAR(10) NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','full','completed','cancelled')),
  reminder_sent   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (seats_available >= 0 AND seats_available <= total_seats),
  CHECK (
    (cost_split = FALSE AND total_cost IS NULL) OR
    (cost_split = TRUE  AND total_cost IS NOT NULL AND total_cost >= 0)
  )
);

CREATE TABLE ride_requests (
  id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ride_id    INT NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  rider_id   INT NOT NULL REFERENCES users(id),
  status     VARCHAR(10) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected')),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (ride_id, rider_id)
);

CREATE TABLE ratings (
  id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ride_id  INT NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  rater_id INT NOT NULL REFERENCES users(id),
  rated_id INT NOT NULL REFERENCES users(id),
  stars    INT NOT NULL CHECK (stars BETWEEN 1 AND 5),
  comment  TEXT,
  UNIQUE (ride_id, rater_id, rated_id),
  CHECK (rater_id <> rated_id)
);

CREATE TABLE notifications (
  id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message    VARCHAR(300) NOT NULL,
  is_read    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Helpful indexes for the main queries
CREATE INDEX idx_rides_event_zone ON rides (event_id, zone_id, status);
CREATE INDEX idx_requests_rider   ON ride_requests (rider_id);
CREATE INDEX idx_notif_user_read  ON notifications (user_id, is_read);
CREATE INDEX idx_rides_departure  ON rides (departure_time) WHERE status = 'open';
```

*(The partial index on `idx_rides_departure` is PostgreSQL syntax; on MySQL drop the `WHERE` clause.)*

---

## 8. Queries that depend on this design

**Area-based matching** (same zone first, then adjacent zones):

```sql
SELECT r.*,
       CASE WHEN r.zone_id = :rider_zone THEN 0 ELSE 1 END AS zone_rank
FROM rides r
WHERE r.event_id = :event_id
  AND r.status = 'open'
  AND (
        r.zone_id = :rider_zone
     OR r.zone_id IN (SELECT adjacent_zone_id
                      FROM zone_adjacency
                      WHERE zone_id = :rider_zone)
      )
ORDER BY zone_rank, r.departure_time;
```

**Seat-safe approval** (one transaction):

```sql
BEGIN;
UPDATE rides
   SET seats_available = seats_available - 1
 WHERE id = :ride_id AND seats_available > 0;   -- must affect exactly 1 row
UPDATE ride_requests SET status = 'approved' WHERE id = :request_id AND status = 'pending';
UPDATE rides SET status = 'full' WHERE id = :ride_id AND seats_available = 0;
COMMIT;
```

**Cost share shown on booking confirmation** (computed, not stored):

```sql
SELECT r.total_cost / NULLIF(COUNT(rq.id), 0) AS your_share
FROM rides r
JOIN ride_requests rq ON rq.ride_id = r.id AND rq.status = 'approved'
WHERE r.id = :ride_id AND r.cost_split
GROUP BY r.id, r.total_cost;
```

**Refresh a user's average rating** (inside the rating-insert transaction):

```sql
UPDATE users
   SET avg_rating = (SELECT ROUND(AVG(stars), 2) FROM ratings WHERE rated_id = :user_id)
 WHERE id = :user_id;
```

---

## 9. Summary

| Table | 1NF | 2NF | 3NF | BCNF | Notes |
|---|:-:|:-:|:-:|:-:|---|
| users | ✅ | ✅ | ✅ | ✅ | `avg_rating` is derived (kept deliberately) |
| zones | ✅ | ✅ | ✅ | ✅ | |
| zone_adjacency | ✅ | ✅ | ✅ | ✅ | store both directions |
| events | ✅ | ✅ | ✅ | ✅ | add `location`, `parent_event_id`, `created_by` |
| rides | ✅ | ✅ | ✅ | ✅ | `seats_available` derived (kept deliberately) |
| ride_requests | ✅ | ✅ | ✅ | ✅ | add `UNIQUE (ride_id, rider_id)` |
| ratings | ✅ | ✅ | ✅ | ✅ | add `UNIQUE` + no-self-rating CHECK |
| notifications | ✅ | ✅ | ✅ | ✅ | optional `ride_id` later |

The schema is in **BCNF** for every stored attribute. The only departures from a pure normal form are two intentional, transaction-protected derived columns (`users.avg_rating`, `rides.seats_available`), both justified in §5.
