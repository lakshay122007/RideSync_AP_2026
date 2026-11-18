-- READ R1: Login by email
SELECT id, name, email, password_hash, avg_rating
FROM users
WHERE email = $1;

-- READ R2: Public profile with rating count and completed ride counts
SELECT u.id,
       u.name,
       u.avg_rating,
       (SELECT COUNT(*) FROM ratings g WHERE g.rated_id = u.id) AS rating_count,
       (SELECT COUNT(*) FROM rides d
         WHERE d.driver_id = u.id AND d.status = 'completed') AS rides_driven,
       (SELECT COUNT(*) FROM ride_requests q
          JOIN rides t ON t.id = q.ride_id
         WHERE q.rider_id = u.id AND q.status = 'approved'
           AND t.status = 'completed') AS rides_taken
FROM users u
WHERE u.id = $1;

-- READ R3: List all pickup zones
SELECT id, name
FROM zones
ORDER BY name;

-- READ R4: Browse events with ride count and open seats (optional category, search text, upcoming only)
SELECT e.id,
       e.name,
       e.event_date,
       e.location,
       e.category,
       e.is_recurring,
       COUNT(r.id) FILTER (WHERE r.status IN ('open', 'full')
                             AND r.departure_time > NOW()) AS ride_count,
       COALESCE(SUM(r.seats_available) FILTER (WHERE r.status = 'open'
                             AND r.departure_time > NOW()), 0) AS open_seats
FROM events e
LEFT JOIN rides r ON r.event_id = e.id
WHERE ($1::text IS NULL OR e.category = $1)
  AND ($2::text IS NULL OR e.name ILIKE '%' || $2 || '%' OR e.location ILIKE '%' || $2 || '%')
  AND ($3::boolean = FALSE OR e.event_date > NOW())
GROUP BY e.id
ORDER BY e.event_date;

-- READ R5: Event detail with creator
SELECT e.id,
       e.name,
       e.event_date,
       e.location,
       e.category,
       e.is_recurring,
       e.parent_event_id,
       e.created_by,
       u.name AS created_by_name
FROM events e
JOIN users u ON u.id = e.created_by
WHERE e.id = $1;

-- READ R6: Rides for an event ranked by zone proximity (same zone, adjacent zone, other)
SELECT r.id,
       r.departure_time,
       r.total_seats,
       r.seats_available,
       r.status,
       r.cost_split,
       r.total_cost,
       z.name AS zone_name,
       u.id AS driver_id,
       u.name AS driver_name,
       u.avg_rating AS driver_rating,
       CASE WHEN r.cost_split
            THEN ROUND(r.total_cost / GREATEST(ap.approved, 1), 2)
       END AS cost_share,
       CASE WHEN r.zone_id = $2::int THEN 0
            WHEN adj.zone_id IS NOT NULL THEN 1
            ELSE 2
       END AS zone_rank
FROM rides r
JOIN users u ON u.id = r.driver_id
JOIN zones z ON z.id = r.zone_id
LEFT JOIN zone_adjacency adj
       ON adj.zone_id = $2::int AND adj.adjacent_zone_id = r.zone_id
JOIN LATERAL (SELECT COUNT(*) AS approved
                FROM ride_requests q
               WHERE q.ride_id = r.id AND q.status = 'approved') ap ON TRUE
WHERE r.event_id = $1
  AND r.status IN ('open', 'full')
  AND r.departure_time > NOW()
ORDER BY zone_rank, r.departure_time;

-- READ R7: Ride detail with event, zone, driver and current cost share
SELECT r.id,
       r.event_id,
       e.name AS event_name,
       e.event_date,