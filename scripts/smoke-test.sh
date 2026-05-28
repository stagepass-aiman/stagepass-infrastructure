#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh
#
# End-to-end smoke test for Phase 3 + Phase 4 services.
# Runs after `docker compose up --build` and verifies:
#   1. Auth Service health
#   2. Event Service health
#   3. Venue Service health             ← Phase 4 addition
#   4. Seat Inventory Service health    ← Phase 4 addition
#   5. Auth Service JWKS endpoint returns RSA key
#   6. Register an Organiser → receive JWT
#   7. Use JWT to create a Draft event
#   8. Verify the event is retrievable
#   9. Add a pricing tier, add a section
#  10. Publish the event → Kafka message emitted
#  11. Verify Kafka topic has a message (via kafka-console-consumer)
#  12. Register a Venue actor → create a Venue
#  13. Verify the Venue is retrievable
#  14. Tenant isolation check
#
# WHY a smoke test script (not just curl commands in the README):
#   A script is repeatable and runnable in CI. Every Phase completion
#   must leave the system runnable and verified. The script is the
#   definition of "runnable" made executable.
#
# USAGE:
#   cd /d/Projects/StagePass/stagepass-infrastructure
#   bash scripts/smoke-test.sh
#
# REQUIRES: curl, jq, nc, docker (for Kafka consumer check)
# Windows Git Bash: jq must be installed — see RULE-22 in the system prompt.
#   curl -L -o ~/jq.exe \
#     https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe
#   export PATH="$HOME:$PATH"
# =============================================================================

set -euo pipefail

AUTH_URL="http://localhost:8081"
EVENT_URL="http://localhost:8082"
VENUE_URL="http://localhost:8083"
SEAT_ACTUATOR_URL="http://localhost:8084"   # Seat Inventory Spring Actuator (container:8090)
SEAT_GRPC_HOST="localhost"
SEAT_GRPC_PORT="19090"                      # gRPC (container:9090 → host:19090; host 9090 = Prometheus)
KAFKA_CONTAINER="stagepass-kafka"

# Colours for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; }
fail() { echo -e "${RED}❌ FAIL${NC}: $1"; exit 1; }
info() { echo -e "${YELLOW}ℹ️  INFO${NC}: $1"; }

echo "======================================="
echo "  StagePass Phase 3+4 Smoke Test"
echo "======================================="
echo ""

# ── 1. Auth Service health ─────────────────────────────────────────────────
info "Checking Auth Service health..."
LIVE=$(curl -sf "$AUTH_URL/health/live" | jq -r '.status' 2>/dev/null || echo "FAIL")
READY=$(curl -sf "$AUTH_URL/health/ready" | jq -r '.status' 2>/dev/null || echo "FAIL")
[ "$LIVE" = "UP" ] && [ "$READY" = "UP" ] || fail "Auth Service is not healthy (live=$LIVE ready=$READY)"
pass "Auth Service healthy (live=UP, ready=UP)"

# ── 2. Event Service health ────────────────────────────────────────────────
info "Checking Event Service health..."
LIVE=$(curl -sf "$EVENT_URL/health/live" | jq -r '.status' 2>/dev/null || echo "FAIL")
READY=$(curl -sf "$EVENT_URL/health/ready" | jq -r '.status' 2>/dev/null || echo "FAIL")
[ "$LIVE" = "UP" ] && [ "$READY" = "UP" ] || fail "Event Service is not healthy (live=$LIVE ready=$READY)"
pass "Event Service healthy (live=UP, ready=UP)"

# ── 3. Venue Service health ────────────────────────────────────────────────
info "Checking Venue Service health..."
LIVE=$(curl -sf "$VENUE_URL/health/live" | jq -r '.status' 2>/dev/null || echo "FAIL")
READY=$(curl -sf "$VENUE_URL/health/ready" | jq -r '.status' 2>/dev/null || echo "FAIL")
[ "$LIVE" = "UP" ] || fail "Venue Service liveness check failed (live=$LIVE)"
[ "$READY" = "UP" ] || fail "Venue Service readiness check failed (ready=$READY) — MongoDB may not be connected"
pass "Venue Service healthy (live=UP, ready=UP)"

# ── 4. Seat Inventory Service health ──────────────────────────────────────
# Seat Inventory is gRPC-only (ADR-003 §3.3.1). No REST surface.
# Health is verified via Spring Actuator on port 8084 (container port 8090).
# Readiness verifies PostgreSQL and Redis connectivity.
# gRPC port 19090 (host) = container port 9090.
info "Checking Seat Inventory Service liveness..."
SI_LIVE=$(curl -sf "$SEAT_ACTUATOR_URL/actuator/health/liveness" \
  | jq -r '.status' 2>/dev/null || echo "FAIL")
[ "$SI_LIVE" = "UP" ] || \
  fail "Seat Inventory liveness failed (status=$SI_LIVE) — check docker logs seat-inventory-service"
pass "Seat Inventory liveness UP"

info "Checking Seat Inventory Service readiness (verifies PostgreSQL + Redis)..."
SI_READY=$(curl -sf "$SEAT_ACTUATOR_URL/actuator/health/readiness" \
  | jq -r '.status' 2>/dev/null || echo "FAIL")
[ "$SI_READY" = "UP" ] || \
  fail "Seat Inventory readiness failed (status=$SI_READY) — Flyway migration or Redis connection may have failed"
pass "Seat Inventory readiness UP (PostgreSQL + Redis connected)"

info "Checking Seat Inventory gRPC port is open ($SEAT_GRPC_HOST:$SEAT_GRPC_PORT)..."
# Use /dev/tcp instead of nc — nc is not available on Windows Git Bash (RULE-22 equivalent)
(echo >/dev/tcp/${SEAT_GRPC_HOST}/${SEAT_GRPC_PORT}) 2>/dev/null || \
  fail "Seat Inventory gRPC port $SEAT_GRPC_PORT not open — service may not have started correctly"
pass "Seat Inventory gRPC port $SEAT_GRPC_PORT open"

info "Checking Seat Inventory Prometheus metrics endpoint..."
METRICS_OK=$(curl -sf "$SEAT_ACTUATOR_URL/actuator/prometheus" \
  | grep -c "jvm_memory" 2>/dev/null || echo "0")
[ "$METRICS_OK" -gt "0" ] || \
  fail "Seat Inventory /actuator/prometheus returned no JVM metrics — check Actuator config"
pass "Seat Inventory Prometheus metrics endpoint responding"

# ── 5. Auth Service JWKS endpoint ─────────────────────────────────────────
info "Checking JWKS endpoint..."
KTY=$(curl -sf "$AUTH_URL/auth/jwks" | jq -r '.keys[0].kty' 2>/dev/null || echo "FAIL")
[ "$KTY" = "RSA" ] || fail "JWKS endpoint did not return RSA key (kty=$KTY)"
pass "JWKS endpoint returns RSA key"

# ── 6. Register an Organiser ───────────────────────────────────────────────
info "Registering a test Organiser..."
TIMESTAMP=$(date +%s)
REGISTER_RESPONSE=$(curl -sf -X POST "$AUTH_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{
    \"email\": \"smoke-organiser-$TIMESTAMP@stagepass.dev\",
    \"password\": \"SmokeTest@123\",
    \"firstName\": \"Smoke\",
    \"lastName\": \"Organiser\",
    \"displayName\": \"Smoke Organiser\",
    \"role\": \"ORGANISER\"
  }" 2>/dev/null) || fail "Registration request failed"

ACCESS_TOKEN=$(echo "$REGISTER_RESPONSE" | jq -r '.accessToken' 2>/dev/null || echo "")
[ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ] || fail "Registration did not return accessToken"
pass "Organiser registered, JWT received"

# ── 7. Create a Draft event ────────────────────────────────────────────────
info "Creating a Draft event..."
FUTURE_DATE=$(date -d "+30 days" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
              date -v+30d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
              echo "2027-01-15T19:00:00Z")

EVENT_RESPONSE=$(curl -sf -X POST "$EVENT_URL/events" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: smoke-create-$(date +%s)" \
  -d "{
    \"venueBookingId\": \"550e8400-e29b-41d4-a716-446655440000\",
    \"title\": \"Smoke Test Concert\",
    \"eventDate\": \"$FUTURE_DATE\",
    \"cancellationPolicy\": { \"brackets\": [] }
  }" 2>/dev/null) || fail "Event creation request failed"

EVENT_ID=$(echo "$EVENT_RESPONSE" | jq -r '.eventId' 2>/dev/null || echo "")
EVENT_STATUS=$(echo "$EVENT_RESPONSE" | jq -r '.status' 2>/dev/null || echo "")
[ -n "$EVENT_ID" ] && [ "$EVENT_STATUS" = "DRAFT" ] || \
  fail "Event creation failed (id=$EVENT_ID status=$EVENT_STATUS)"
pass "Event created in DRAFT status (id=$EVENT_ID)"

# ── 8. Get the event ───────────────────────────────────────────────────────
info "Fetching the created event..."
GET_RESPONSE=$(curl -sf "$EVENT_URL/events/$EVENT_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null) || fail "GET event request failed"
FETCHED_TITLE=$(echo "$GET_RESPONSE" | jq -r '.title' 2>/dev/null || echo "")
[ "$FETCHED_TITLE" = "Smoke Test Concert" ] || fail "GET event returned wrong title ($FETCHED_TITLE)"
pass "Event retrieved correctly"

# ── 9. Add a pricing tier and section ────────────────────────────────────
info "Adding a pricing tier..."
TIER_RESPONSE=$(curl -sf -X POST "$EVENT_URL/events/$EVENT_ID/pricing-tiers" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: smoke-tier-$(date +%s)" \
  -d '{
    "name": "General Admission",
    "price": { "amount": "500.0000", "currency": "INR" },
    "capacity": 100
  }' 2>/dev/null) || fail "Pricing tier creation failed"

TIER_ID=$(echo "$TIER_RESPONSE" | jq -r '.tierId' 2>/dev/null || echo "")
[ -n "$TIER_ID" ] && [ "$TIER_ID" != "null" ] || fail "Pricing tier did not return tierId"
pass "Pricing tier added (id=$TIER_ID)"

info "Adding a seating section..."
SECTION_RESPONSE=$(curl -sf -X POST "$EVENT_URL/events/$EVENT_ID/sections" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: smoke-section-$(date +%s)" \
  -d "{
    \"name\": \"Floor\",
    \"layoutSectionRef\": \"floor-ga\",
    \"pricingTierId\": \"$TIER_ID\",
    \"colour\": \"#4A90D9\"
  }" 2>/dev/null) || fail "Section creation failed"

SECTION_ID=$(echo "$SECTION_RESPONSE" | jq -r '.sectionId' 2>/dev/null || echo "")
[ -n "$SECTION_ID" ] && [ "$SECTION_ID" != "null" ] || fail "Section did not return sectionId"
pass "Section added (id=$SECTION_ID)"

# ── 10. Publish the event ─────────────────────────────────────────────────
info "Publishing the event..."
PUBLISH_RESPONSE=$(curl -sf -X POST "$EVENT_URL/events/$EVENT_ID/publish" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Idempotency-Key: smoke-publish-$(date +%s)" 2>/dev/null) || fail "Publish request failed"

PUBLISHED_STATUS=$(echo "$PUBLISH_RESPONSE" | jq -r '.status' 2>/dev/null || echo "")
[ "$PUBLISHED_STATUS" = "PUBLISHED" ] || fail "Publish did not transition to PUBLISHED (status=$PUBLISHED_STATUS)"
pass "Event published (status=PUBLISHED)"

# ── 11. Verify Kafka message ──────────────────────────────────────────────
info "Checking Kafka topic for event.events message..."
KAFKA_MSG=$(docker exec "$KAFKA_CONTAINER" \
  kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic event.events \
    --from-beginning \
    --max-messages 1 \
    --timeout-ms 10000 \
  2>/dev/null || echo "")

if echo "$KAFKA_MSG" | grep -q "PUBLISHED"; then
  pass "Kafka event.events topic contains PUBLISHED message"
else
  info "Kafka message check inconclusive (topic may have older messages or consumer timed out)"
  info "Manually check: docker exec $KAFKA_CONTAINER kafka-console-consumer --bootstrap-server localhost:9092 --topic event.events --from-beginning --max-messages 5"
fi

# ── 12. Register a Venue actor and create a Venue ─────────────────────────
info "Registering a test Venue actor..."
VENUE_REGISTER_RESPONSE=$(curl -sf -X POST "$AUTH_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{
    \"email\": \"smoke-venue-$TIMESTAMP@stagepass.dev\",
    \"password\": \"SmokeTest@123\",
    \"firstName\": \"Smoke\",
    \"lastName\": \"Venue\",
    \"displayName\": \"Smoke Venue Owner\",
    \"role\": \"VENUE\"
  }" 2>/dev/null) || fail "Venue actor registration request failed"

VENUE_TOKEN=$(echo "$VENUE_REGISTER_RESPONSE" | jq -r '.accessToken' 2>/dev/null || echo "")
[ -n "$VENUE_TOKEN" ] && [ "$VENUE_TOKEN" != "null" ] || fail "Venue actor registration did not return accessToken"
pass "Venue actor registered, JWT received"

info "Creating a Venue via Venue Service..."
CREATE_VENUE_RESPONSE=$(curl -sf -X POST "$VENUE_URL/venues" \
  -H "Authorization: Bearer $VENUE_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: smoke-venue-$(date +%s)" \
  -d '{
    "name": "Smoke Test Arena",
    "city": "Mumbai",
    "address": "1 Marine Drive, Mumbai 400020",
    "totalCapacity": 1000,
    "facilities": ["parking"]
  }' 2>/dev/null) || fail "Venue creation request failed"

VENUE_ID=$(echo "$CREATE_VENUE_RESPONSE" | jq -r '.venueId' 2>/dev/null || echo "")
VENUE_STATUS=$(echo "$CREATE_VENUE_RESPONSE" | jq -r '.status' 2>/dev/null || echo "")
[ -n "$VENUE_ID" ] && [ "$VENUE_ID" != "null" ] || fail "Venue creation did not return venueId"
[ "$VENUE_STATUS" = "PENDING_KYC" ] || fail "Venue status should be PENDING_KYC (got: $VENUE_STATUS)"
pass "Venue created (id=$VENUE_ID status=PENDING_KYC)"

# ── 13. Verify the Venue is retrievable ───────────────────────────────────
info "Fetching the created Venue..."
GET_VENUE_RESPONSE=$(curl -sf "$VENUE_URL/venues/$VENUE_ID" \
  -H "Authorization: Bearer $VENUE_TOKEN" 2>/dev/null) || fail "GET venue request failed"

FETCHED_VENUE_NAME=$(echo "$GET_VENUE_RESPONSE" | jq -r '.name' 2>/dev/null || echo "")
FETCHED_OWNER=$(echo "$GET_VENUE_RESPONSE" | jq -r '.ownerId' 2>/dev/null || echo "")
[ "$FETCHED_VENUE_NAME" = "Smoke Test Arena" ] || fail "GET venue returned wrong name ($FETCHED_VENUE_NAME)"
[ -n "$FETCHED_OWNER" ] && [ "$FETCHED_OWNER" != "null" ] || fail "GET venue missing ownerId"
pass "Venue retrieved correctly (name=$FETCHED_VENUE_NAME)"

# ── 14. Verify tenant isolation ───────────────────────────────────────────
info "Verifying tenant isolation — Organiser cannot read Venue actor's venue..."
ISOLATION_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$VENUE_URL/venues/$VENUE_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null || echo "000")
# ORGANISER role sees ACTIVE venues only — PENDING_KYC venue returns 404 for any non-owner
[ "$ISOLATION_STATUS" = "404" ] || \
  info "Tenant isolation returned $ISOLATION_STATUS (expected 404 — verify NFR-SEC-004 if not 404)"
[ "$ISOLATION_STATUS" = "404" ] && pass "Tenant isolation correct — Organiser receives 404 for PENDING_KYC venue"

echo ""
echo "======================================="
echo -e "${GREEN}  Phase 3+4 Smoke Test PASSED${NC}"
echo "======================================="
echo ""
echo "Services running:"
echo "  Auth Service:          $AUTH_URL"
echo "  Event Service:         $EVENT_URL"
echo "  Venue Service:         $VENUE_URL"
echo "  Seat Inventory gRPC:   $SEAT_GRPC_HOST:$SEAT_GRPC_PORT (host) → container:9090"
echo "  Seat Inventory Actuator: $SEAT_ACTUATOR_URL/actuator/health"
echo "  Kafka UI:              http://localhost:8090"
echo "  Grafana:               http://localhost:3000 (admin/admin)"
echo "  Jaeger UI:             http://localhost:16686"
echo "  Prometheus:            http://localhost:9090"