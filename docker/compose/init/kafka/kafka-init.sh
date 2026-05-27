#!/bin/bash
# =============================================================================
# kafka-init.sh — Topic creation for Phase 2 local dev
#
# SASL/SCRAM deferred to Phase 3. See commit message for rationale.
# This script only creates topics. ACLs will be added in Phase 3.
#
# CHANGELOG:
#   Phase 4 — Added venue.events and venue.events.dlq (Venue Service Outbox).
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

echo "[kafka-init] All topics created."
echo "[kafka-init] Phase 4 init complete."
echo "[kafka-init] NOTE: SASL/SCRAM deferred to Phase 3. THR-PLAT-01 tracked."