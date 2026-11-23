#!/bin/bash
set -e

DB="${1:-carpool}"
RUNS=3
HERE="$(cd "$(dirname "$0")" && pwd)"
DBMS="$(cd "$HERE/.." && pwd)"
QUERIES="$DBMS/04_queries.sql"
PLANS="$DBMS/plans"
OUT="$DBMS/05_query_timings.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ridesync.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

emit() { printf '%s\n' "$1"; }

if ! command -v psql >/dev/null 2>&1; then
  echo "psql was not found. Install PostgreSQL first."
  exit 1
fi
if ! psql -X -q -d "$DB" -c "SELECT 1" >/dev/null 2>&1; then
  echo "Cannot connect to database '$DB'. Check that PostgreSQL is running and the database exists."
  exit 1
fi
if [ ! -f "$QUERIES" ]; then
  echo "Missing $QUERIES"
  exit 1
fi

awk -v work="$WORK" '
/^-- [RW][0-9]+ [|] (READ|WRITE) [|]/ {
  if (out != "") close(out)
  id = $2
  out = work "/" id ".sql"
  title = $0
  sub(/^-- [RW][0-9]+ [|] (READ|WRITE) [|] /, "", title)
  sub(/ +\[TXN:.*$/, "", title)
  print id "|" $4 "|" title >> (work "/titles.txt")
  next
}
/^--/ { next }
out != "" { print > out }
' "$QUERIES"

mkdir -p "$PLANS"
rm -f "$PLANS"/[RW]*.txt
: > "$WORK/results.txt"

{
  emit "\\i '$HERE/prelude.sql'"
  emit '\echo uid=:uid rated=:rated rider=:rider ev=:ev ev_busy=:ev_busy pend_req=:pend_req pend_ride=:pend_ride appr_req=:appr_req done_ride=:done_ride w9_ride=:w9_ride notif=:notif'
} > "$WORK/fixtures.sql"
psql -X -q -d "$DB" -f "$WORK/fixtures.sql" < /dev/null > "$WORK/fixtures.txt"

echo "Database: $DB"
echo "Running every query $RUNS times with EXPLAIN (ANALYZE, BUFFERS)..."

while IFS='|' read -r id setup args; do
  case "$id" in
    ''|'#'*) continue ;;
  esac
  if [ "$setup" = "-" ]; then setup=""; fi
  kind="$(grep "^$id|" "$WORK/titles.txt" | cut -d'|' -f2)"
  title="$(grep "^$id|" "$WORK/titles.txt" | cut -d'|' -f3-)"
  if [ ! -f "$WORK/$id.sql" ]; then
    echo "Query $id is in params.tsv but not in 04_queries.sql"
    exit 1
  fi

  {
    emit "-- $id | $kind | $title"
    if [ -n "$args" ]; then emit "-- Parameters: $args"; else emit "-- Parameters: none"; fi
    if [ -n "$setup" ]; then emit "-- Run first inside the same transaction: $setup"; fi
    emit "-- Parameter values used: $(cat "$WORK/fixtures.txt")"
    emit "-- Every run is rolled back, so the data is the same for each run."
    emit ""
    sed 's/^/-- /' "$WORK/$id.sql"
    emit ""
  } > "$PLANS/$id.txt"

  run=1
  while [ "$run" -le "$RUNS" ]; do
    {
      emit '\set ON_ERROR_STOP on'
      emit "\\i '$HERE/prelude.sql'"
      emit 'BEGIN;'
      if [ -n "$setup" ]; then emit "$setup"; fi
      emit 'PREPARE q AS'
      cat "$WORK/$id.sql"
      emit '\pset format unaligned'
      emit '\pset tuples_only on'
      emit "\\o '$WORK/plan.txt'"
      if [ -n "$args" ]; then
        emit "EXPLAIN (ANALYZE, BUFFERS) EXECUTE q($args);"
      else
        emit "EXPLAIN (ANALYZE, BUFFERS) EXECUTE q;"
      fi
      emit '\o'
      emit 'ROLLBACK;'
    } > "$WORK/run.sql"

    if ! psql -X -q -d "$DB" -f "$WORK/run.sql" < /dev/null > "$WORK/out.txt" 2>&1; then
      echo "Query $id failed on run $run:"
      cat "$WORK/out.txt"
      exit 1
    fi

    t="$(awk '/Execution Time:/ {print $3}' "$WORK/plan.txt")"
    if [ -z "$t" ]; then
      echo "No execution time found for $id run $run"
      exit 1
    fi
    case "$run" in
      1) t1="$t"; cp "$WORK/plan.txt" "$WORK/plan_run1.txt" ;;
      2) t2="$t" ;;
      3) t3="$t" ;;
    esac
    { emit "-- Run $run"; cat "$WORK/plan.txt"; emit ""; } >> "$PLANS/$id.txt"
    run=$((run + 1))
  done

  avg="$(awk -v a="$t1" -v b="$t2" -v c="$t3" 'BEGIN { printf "%.3f", (a + b + c) / 3 }')"
  scan="$(awk '
  {
    line = $0
    sub(/^ */, "", line)
    sub(/^-> +/, "", line)
    if (match(line, /^(Parallel )?(Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan)/)) {
      kind_found = substr(line, RSTART, RLENGTH)
      sub(/^Parallel /, "", kind_found)
      if (!(kind_found in seen)) {
        seen[kind_found] = 1
        list = (list == "" ? kind_found : list ", " kind_found)
      }
    }
  }
  END { print list }' "$WORK/plan_run1.txt")"
  if [ -z "$scan" ]; then scan="—"; fi

  emit "$id|$kind|$title|$t1|$t2|$t3|$avg|$scan" >> "$WORK/results.txt"
  printf '  %-4s %-5s avg %9s ms   %s\n' "$id" "$kind" "$avg" "$scan"
done < "$HERE/params.tsv"

PGVER="$(psql -X -At -d "$DB" -c 'SHOW server_version')"
COUNTS="$(psql -X -At -F '|' -d "$DB" -c "
SELECT 'users', COUNT(*) FROM users
UNION ALL SELECT 'zones', COUNT(*) FROM zones
UNION ALL SELECT 'zone_adjacency', COUNT(*) FROM zone_adjacency
UNION ALL SELECT 'events', COUNT(*) FROM events
UNION ALL SELECT 'rides', COUNT(*) FROM rides
UNION ALL SELECT 'ride_requests', COUNT(*) FROM ride_requests
UNION ALL SELECT 'ratings', COUNT(*) FROM ratings
UNION ALL SELECT 'notifications', COUNT(*) FROM notifications
ORDER BY 1")"

{
  emit "# Query timings"
  emit ""
  emit "Baseline timings for every query in \`04_queries.sql\`, taken on the schema from \`03_schema.sql\` without any changes to indexes or queries."
  emit ""
  emit "## Setup"
  emit ""
  emit "- Date: $(date '+%Y-%m-%d')"
  emit "- PostgreSQL: $PGVER"
  emit "- Machine: $(uname -sm)"
  emit "- Data: generated by \`tools/seed_bulk.sql\`, followed by \`VACUUM ANALYZE\`"
  emit ""
  emit "| Table | Rows |"
  emit "|-------|-----:|"
  emit "$COUNTS" | awk -F'|' '{ printf "| %s | %s |\n", $1, $2 }'
  emit ""
  emit "## Method"
  emit ""
  emit "- Each query ran $RUNS times with \`EXPLAIN (ANALYZE, BUFFERS)\`, each time in a new psql session."
  emit "- The query is prepared and executed with real values taken from the data (listed below)."
  emit "- Write queries run inside a transaction that is rolled back, so every run sees the same data. Queries that need a certain state (W7, W8, W19) run a small setup statement first, shown at the top of their plan file."
  emit "- The time is the \`Execution Time\` that PostgreSQL reports. It leaves out network time and Node.js time."
  emit "- Run 1 can be slower than runs 2 and 3 because the data may not be in cache yet."
  emit "- Scan type lists the table scan nodes in the plan of run 1. The full plans are in \`plans/<id>.txt\`."
  emit ""
  emit "Values used for the parameters: \`$(cat "$WORK/fixtures.txt")\`"
  emit ""
  emit "## Timings"
  emit ""
  emit "| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |"
  emit "|-------|------|--------------|-----------:|-----------:|-----------:|-------------:|-----------|"
  awk -F'|' '{ printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8 }' "$WORK/results.txt"
  emit ""
  emit "## Observations"
  emit ""
  emit "Slowest five by average time:"
  emit ""
  sort -t'|' -k7,7 -n -r "$WORK/results.txt" | head -5 | awk -F'|' '{ printf "- %s (%s): %s ms, %s\n", $1, $3, $7, $8 }'
  emit ""
  SEQ="$(awk -F'|' '$8 ~ /Seq Scan/ { printf "%s ", $1 }' "$WORK/results.txt")"
  if [ -n "$SEQ" ]; then
    emit "Queries whose plan contains a sequential scan: $SEQ"
  else
    emit "No query plan contains a sequential scan."
  fi
} > "$OUT"

echo ""
echo "Wrote $OUT"
echo "Wrote $(ls "$PLANS" | wc -l | tr -d ' ') plan files in $PLANS"
