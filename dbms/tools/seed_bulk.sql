\set ON_ERROR_STOP on

TRUNCATE notifications, ratings, ride_requests, rides, events, users RESTART IDENTITY CASCADE;

INSERT INTO users (name, email, password_hash)
SELECT 'User ' || i, 'user' || i || '@ridesync.test', 'seed-hash'
FROM generate_series(1, 20000) AS i;

INSERT INTO events (name, event_date, location, category, is_recurring, created_by)
SELECT 'Event ' || i,
       date_trunc('hour', NOW()) + ((i % 180) - 120) * INTERVAL '1 day' + (i % 12) * INTERVAL '1 hour',
       'Venue ' || (i % 50),
       (ARRAY['college_fest', 'gym', 'market', 'exam', 'concert', 'custom'])[1 + i % 6],
       i % 10 = 0,
       1 + (i * 37) % 20000
FROM generate_series(1, 2000) AS i;

INSERT INTO rides (event_id, driver_id, zone_id, departure_time, total_seats,
                   cost_split, total_cost, status, reminder_sent)
SELECT e.id,
       1 + (i * 31) % 20000,
       1 + i % 6,
       e.event_date - (1 + i % 5) * INTERVAL '1 hour',
       1 + i % 4,
       i % 3 = 0,
       CASE WHEN i % 3 = 0 THEN 100 + (i % 20) * 10 END,
       CASE
         WHEN e.event_date < NOW() AND i % 20 = 0 THEN 'cancelled'
         WHEN e.event_date < NOW() THEN 'completed'
         ELSE 'open'
       END,
       e.event_date < NOW()
FROM generate_series(1, 60000) AS i
JOIN events e ON e.id = 1 + (i * 13) % 2000;

INSERT INTO ride_requests (ride_id, rider_id, status)
SELECT r.id,
       1 + (r.id * 17 + k * 101) % 20000,
       CASE
         WHEN r.status = 'completed' AND k <= r.total_seats THEN 'approved'
         WHEN r.status = 'completed' THEN 'rejected'
         WHEN r.status = 'cancelled' THEN 'rejected'
         WHEN k = 1 THEN 'approved'
         ELSE 'pending'
       END
FROM rides r
CROSS JOIN generate_series(1, 3) AS k
WHERE 1 + (r.id * 17 + k * 101) % 20000 <> r.driver_id;

UPDATE rides r
SET seats_available = r.total_seats - a.approved_count,
    status = CASE
               WHEN r.status = 'open' AND r.total_seats - a.approved_count = 0 THEN 'full'
               ELSE r.status
             END
FROM (SELECT ride_id, COUNT(*) AS approved_count
      FROM ride_requests
      WHERE status = 'approved'
      GROUP BY ride_id) a
WHERE a.ride_id = r.id;

ALTER TABLE ratings DISABLE TRIGGER ratings_refresh_avg;

INSERT INTO ratings (ride_id, rater_id, rated_id, stars, comment)
SELECT rq.ride_id, rq.rider_id, r.driver_id, 1 + rq.id % 5,
       CASE WHEN rq.id % 4 = 0 THEN 'Good ride' END
FROM ride_requests rq
JOIN rides r ON r.id = rq.ride_id
WHERE r.status = 'completed' AND rq.status = 'approved' AND rq.id % 2 = 0
UNION ALL
SELECT rq.ride_id, r.driver_id, rq.rider_id, 1 + rq.id % 5, NULL
FROM ride_requests rq
JOIN rides r ON r.id = rq.ride_id
WHERE r.status = 'completed' AND rq.status = 'approved' AND rq.id % 3 = 0;

UPDATE users u
SET avg_rating = a.avg_stars
FROM (SELECT rated_id, ROUND(AVG(stars)::numeric, 2) AS avg_stars
      FROM ratings
      GROUP BY rated_id) a
WHERE a.rated_id = u.id;

ALTER TABLE ratings ENABLE TRIGGER ratings_refresh_avg;

INSERT INTO notifications (user_id, message, is_read, created_at)
SELECT 1 + (i * 29) % 20000,
       'Notification ' || i,
       i % 3 <> 0,
       NOW() - (i % 43200) * INTERVAL '1 minute'
FROM generate_series(1, 200000) AS i;

VACUUM ANALYZE;

SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'zones', COUNT(*) FROM zones
UNION ALL SELECT 'zone_adjacency', COUNT(*) FROM zone_adjacency
UNION ALL SELECT 'events', COUNT(*) FROM events
UNION ALL SELECT 'rides', COUNT(*) FROM rides
UNION ALL SELECT 'ride_requests', COUNT(*) FROM ride_requests
UNION ALL SELECT 'ratings', COUNT(*) FROM ratings
UNION ALL SELECT 'notifications', COUNT(*) FROM notifications;
