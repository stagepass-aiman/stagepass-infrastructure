#!/bin/bash
# =============================================================================
# kafka-init.sh — Topic creation for Phase 2 local dev
#
# SASL/SCRAM deferred to Phase 3. See commit message for rationale.
# This script only creates topics. ACLs will be added in Phase 3.
#
# CHANGELOG:
#   Phase 4 — Added venue.events and venue.events.dlq (Venue Service Outbox).
#   Phase 4 — Added seat.state-changes (6 partitions, already existed —
#              retained with correct partition count), flash-sale.hold-requests,
#              flash-sale.hold-results, and their .dlq counterparts
#              (Seat Inventory Service + ADR-007 flash sale queue pattern).
# =============================================================================
set -euo pipefail

KAFKA_BOOTSTRAP="kafka:9092"

cat > /tmp/admin.properties <<EOF
security.protocol=PLAINTEXT
EOF

echo "[kafka-init] Waiting for Kafka broker..."
until kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties --list > /dev/null 2>&1; do
  echo "[kafka-init] Not ready, retrying in 5s..."
  sleep 5
done
echo "[kafka-init] Broker ready."

create_topic() {
  local topic="$1"
  local partitions="${2:-3}"
  local retention_ms="${3:-604800000}"
  kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
    --command-config /tmp/admin.properties \
    --create --if-not-exists \
    --topic "${topic}" \
    --partitions "${partitions}" \
    --replication-factor 1 \
    --config retention.ms="${retention_ms}"
  kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
    --command-config /tmp/admin.properties \
    --create --if-not-exists \
    --topic "${topic}.dlq" \
    --partitions 1 \
    --replication-factor 1 \
    --config retention.ms=1209600000
}

echo "[kafka-init] Creating topics..."
create_topic "booking.commands"      3  604800000
create_topic "booking.events"        3  2592000000
create_topic "seat.state-changes"    6  86400000
create_topic "payment.events"        3  2592000000
create_topic "ticket.events"         3  604800000
create_topic "notification.outbox"   3  604800000
create_topic "fraud.scored"          3  2592000000
create_topic "waitlist.offers"       3  604800000
create_topic "disbursement.events"   3  7776000000
create_topic "analytics.ingest"      6  604800000
create_topic "event.published"       3  2592000000
create_topic "event.cancelled"       3  2592000000
create_topic "venue.suspended"       3  604800000

# ── Event Service topics (Phase 3) ──────────────────────────────────────────
# event.events consolidates all event domain messages (created, published,
# cancelled, postponed) into one topic. Consumers filter by message type.
# 12 partitions: higher than other topics — event publishing is the entry
# point for Search Service indexing (NFR-PERF-010: indexed within 30s).
# NOTE: event.published and event.cancelled above are superseded by
# event.events but kept for backward compatibility.
kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "event.events" \
  --partitions 12 \
  --replication-factor 1 \
  --config retention.ms=2592000000   # 30 days — replay source for Search Service

kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "event.events.dlq" \
  --partitions 12 \
  --replication-factor 1 \
  --config retention.ms=1209600000   # 14 days

kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "event.commands" \
  --partitions 12 \
  --replication-factor 1 \
  --config retention.ms=604800000    # 7 days

kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "event.commands.dlq" \
  --partitions 12 \
  --replication-factor 1 \
  --config retention.ms=1209600000   # 14 days

# ── Venue Service topics (Phase 4) ──────────────────────────────────────────
# venue.events carries all Venue domain messages: VenueCreated, VenueUpdated,
# VenueSuspended, VenueBookingAccepted, VenueBookingRejected.
# Published via Transactional Outbox pattern (NFR-REL-005) — guaranteed
# at-least-once delivery. Consumers must be idempotent (NFR-REL-002).
#
# 6 partitions: venue write volume is lower than booking/event domains.
# Partition key: venueId — all events for one venue land on the same
# partition, preserving per-venue ordering (e.g. VenueCreated before
# VenueSuspended for the same venueId).
#
# 30 day retention: VenueBookingAccepted carries the venueRevenueSharePercentage
# that the Disbursement Service uses to compute RevenueSplit records.
# Sufficient retention allows Disbursement to replay if it misses an event.
kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "venue.events" \
  --partitions 6 \
  --replication-factor 1 \
  --config retention.ms=2592000000   # 30 days

# venue.events.dlq — NFR-REL-007: every topic must have a DLQ.
# Prometheus alert fires when DLQ depth > 0 for > 5 minutes.
# 14 day retention: enough time to inspect, fix, and replay failed events.
kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "venue.events.dlq" \
  --partitions 6 \
  --replication-factor 1 \
  --config retention.ms=1209600000   # 14 days

# ── Seat Inventory Service topics (Phase 4) ──────────────────────────────────
# seat.state-changes — published by Seat Inventory Service via Outbox on every
# individual seat state transition (AVAILABLE↔HELD↔BOOKED↔BLOCKED).
# Partition key: eventId — all state changes for one event land on the same
# partition. Required for ordered real-time seat map delivery (NFR-PERF-005:
# p99 < 1s from state change to WebSocket push).
# Consumer groups: notification-service-consumer (WebSocket push),
#                  search-service-consumer (index update),
#                  analytics-service-consumer (ClickHouse).
# NOTE: seat.state-changes is also created via create_topic above (6 partitions,
# 1-day retention). That entry is kept for backward compatibility. Both calls
# use --if-not-exists so the second is a no-op if the topic already exists.
# The retention value above (86400000 = 1 day) is authoritative for local dev.
# Production uses 7 days (604800000) per seat_async.yaml.

# seat.state-changes.dlq is created automatically by the create_topic call
# above. Explicit DLQ creation below is for documentation clarity only
# and is also idempotent via --if-not-exists.
kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "seat.state-changes.dlq" \
  --partitions 1 \
  --replication-factor 1 \
  --config retention.ms=1209600000   # 14 days — already created by create_topic; idempotent

# flash-sale.hold-requests — published by Booking Service when flash sale mode
# is active for an event (GET flash-sale:mode:{eventId} = "active" from Redis).
# Consumed by: seat-inventory-service-consumer (ADR-007 §3.3).
# Partition key: eventId — FIFO ordering per event is the fairness guarantee.
# All requests for one event are serialised on one partition; customers are
# served in the order they submitted their bookings (ADR-007 §3.4).
# 6 partitions (local dev): production uses 24. Supports 6 concurrent flash
# sale events simultaneously without cross-event interference.
# 1 day retention: flash sale requests are time-bounded by expiresAt field
# (hold TTL = 600s). Requests older than 1 day are guaranteed expired.
kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "flash-sale.hold-requests" \
  --partitions 6 \
  --replication-factor 1 \
  --config retention.ms=86400000     # 1 day

kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "flash-sale.hold-requests.dlq" \
  --partitions 1 \
  --replication-factor 1 \
  --config retention.ms=1209600000   # 14 days — P0 alert during active flash sale (NFR-REL-007)

# flash-sale.hold-results — published by Seat Inventory Service after executing
# (or choosing not to execute) the Redis Lua hold script for each request.
# Consumed by: booking-service-consumer (saga advancement — PENDING → SEATS_HELD
# or PENDING → CANCELLED), notification-service-consumer (WebSocket push to
# customer: hold-granted / hold-denied / hold-expired).
# Partition key: customerId — avoids hotspot on popular eventIds; enables
# ordered delivery per customer so hold-granted always arrives before
# booking-confirmed for the same customer.
# 6 partitions (local dev): production uses 12.
# 1 day retention: results are consumed and acted on within seconds.
kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "flash-sale.hold-results" \
  --partitions 6 \
  --replication-factor 1 \
  --config retention.ms=86400000     # 1 day

kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP} \
  --command-config /tmp/admin.properties \
  --create --if-not-exists \
  --topic "flash-sale.hold-results.dlq" \
  --partitions 1 \
  --replication-factor 1 \
  --config retention.ms=1209600000   # 14 days — P0 alert during active flash sale (NFR-REL-007)

echo "[kafka-init] All topics created."
echo "[kafka-init] Phase 4 (Seat Inventory) init complete."
echo "[kafka-init] NOTE: SASL/SCRAM deferred to Phase 3. THR-PLAT-01 tracked."