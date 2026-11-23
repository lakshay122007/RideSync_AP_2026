\set zone 1
\set email 'user1@ridesync.test'

SELECT driver_id AS uid
FROM rides
GROUP BY driver_id
ORDER BY COUNT(*) DESC, driver_id
LIMIT 1
\gset

SELECT rated_id AS rated
FROM ratings
GROUP BY rated_id
ORDER BY COUNT(*) DESC, rated_id
LIMIT 1
\gset

SELECT rider_id AS rider
FROM ride_requests
GROUP BY rider_id
ORDER BY COUNT(*) DESC, rider_id
LIMIT 1
\gset

SELECT e.id AS ev,
       e.created_by AS ev_owner,
       to_char(e.event_date - INTERVAL '1 hour', 'YYYY-MM-DD HH24:MI:SS') AS ev_dep
FROM events e
JOIN rides r ON r.event_id = e.id AND r.status = 'open'
WHERE e.event_date > NOW()
GROUP BY e.id
ORDER BY COUNT(*) DESC, e.id
LIMIT 1
\gset

SELECT e.id AS ev_busy, e.created_by AS ev_busy_owner
FROM events e
JOIN rides r ON r.event_id = e.id
GROUP BY e.id
ORDER BY COUNT(*) DESC, e.id
LIMIT 1
\gset

SELECT rq.id AS pend_req, rq.ride_id AS pend_ride,
       r.driver_id AS pend_driver, rq.rider_id AS pend_rider
FROM ride_requests rq
JOIN rides r ON r.id = rq.ride_id
WHERE rq.status = 'pending' AND r.status = 'open' AND r.seats_available > 0
ORDER BY rq.id
LIMIT 1
\gset

SELECT rq.id AS appr_req, rq.ride_id AS appr_ride, rq.rider_id AS appr_rider
FROM ride_requests rq
JOIN rides r ON r.id = rq.ride_id
WHERE rq.status = 'approved' AND r.status IN ('open', 'full')
ORDER BY rq.id
LIMIT 1
\gset

SELECT r.id AS done_ride, r.driver_id AS done_driver, rq.rider_id AS done_rider
FROM rides r
JOIN ride_requests rq ON rq.ride_id = r.id AND rq.status = 'approved'
WHERE r.status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM ratings x
                  WHERE x.ride_id = r.id
                    AND x.rater_id = rq.rider_id
                    AND x.rated_id = r.driver_id)
ORDER BY r.id
LIMIT 1
\gset

SELECT r.id AS w9_ride
FROM rides r
WHERE r.status = 'open'
  AND r.driver_id <> 1
  AND NOT EXISTS (SELECT 1 FROM ride_requests q
                  WHERE q.ride_id = r.id AND q.rider_id = 1)
ORDER BY r.id
LIMIT 1
\gset

SELECT id AS notif
FROM notifications
WHERE user_id = :uid AND is_read = FALSE
ORDER BY id
LIMIT 1
\gset
