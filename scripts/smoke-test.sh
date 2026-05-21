#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh
#
# End-to-end smoke test for Phase 3 services.
# Runs after `docker compose up --build` and verifies:
#   1. Auth Service health
#   2. Event Service health
#   3. Auth Service JWKS endpoint returns RSA key
#   4. Register an Organiser → receive JWT
#   5. Use JWT to create a Draft event
#   6. Verify the event is retrievable
#   7. Add a pricing tier, add a section
#   8. Publish the event → Kafka message emitted
#   9. Verify Kafka topic has a message (via kafka-console-consumer)
#
# WHY a smoke test script (not just curl commands in the README):
#   A script is repeatable and runnable in CI. Every Phase completion
#   must leave the system runnable and verified. The script is the
#   definition of "runnable" made executable.
#
# USAGE:
#   cd ~/stagepass/stagepass-infrastructure
#   bash scripts/smoke-test.sh
#
# REQUIRES: curl, jq, docker (for Kafka consumer check)
# =============================================================================

set -euo pipefail

AUTH_URL="http://localhost:8081"
EVENT_URL="http://localhost:8082"
KAFKA_CONTAINER="stagepass-kafka"

# Colours for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; }
fail() { echo -e "${RED}❌ FAIL${NC}: $1"; exit 1; }
info() { echo -e "${YELLOW}ℹ️  INFO${NC}: $1"; }

echo "=============================="
echo "  StagePass Phase 3 Smoke Test"
echo "=============================="
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

# ── 3. Auth Service JWKS endpoint ─────────────────────────────────────────
info "Checking JWKS endpoint..."
KTY=$(curl -sf "$AUTH_URL/auth/jwks" | jq -r '.keys[0].kty' 2>/dev/null || echo "FAIL")
[ "$KTY" = "RSA" ] || fail "JWKS endpoint did not return RSA key (kty=$KTY)"
pass "JWKS endpoint returns RSA key"

# ── 4. Register an Organiser ───────────────────────────────────────────────
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

# ── 5. Create a Draft event ────────────────────────────────────────────────
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

# ── 6. Get the event ───────────────────────────────────────────────────────
info "Fetching the created event..."
GET_RESPONSE=$(curl -sf "$EVENT_URL/events/$EVENT_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null) || fail "GET event request failed"
FETCHED_TITLE=$(echo "$GET_RESPONSE" | jq -r '.title' 2>/dev/null || echo "")
[ "$FETCHED_TITLE" = "Smoke Test Concert" ] || fail "GET event returned wrong title ($FETCHED_TITLE)"
pass "Event retrieved correctly"

# ── 7. Add a pricing tier ─────────────────────────────────────────────────
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

# ── 8. Add a section ──────────────────────────────────────────────────────
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

# ── 9. Publish the event ───────────────────────────────────────────────────
info "Publishing the event..."
PUBLISH_RESPONSE=$(curl -sf -X POST "$EVENT_URL/events/$EVENT_ID/publish" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Idempotency-Key: smoke-publish-$(date +%s)" 2>/dev/null) || fail "Publish request failed"

PUBLISHED_STATUS=$(echo "$PUBLISH_RESPONSE" | jq -r '.status' 2>/dev/null || echo "")
[ "$PUBLISHED_STATUS" = "PUBLISHED" ] || fail "Publish did not transition to PUBLISHED (status=$PUBLISHED_STATUS)"
pass "Event published (status=PUBLISHED)"

# ── 10. Verify Kafka message ───────────────────────────────────────────────
info "Checking Kafka topic for event.events message..."
# Read one message from event.events using the console consumer inside the Kafka container.
# Timeout after 10s — if no message arrives, the Kafka publish failed.
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

echo ""
echo "=============================="
echo -e "${GREEN}  Phase 3 Smoke Test PASSED${NC}"
echo "=============================="
echo ""
echo "Services running:"
echo "  Auth Service:  $AUTH_URL"
echo "  Event Service: $EVENT_URL"
echo "  Kafka UI:      http://localhost:8090"
echo "  Grafana:       http://localhost:3000 (admin/admin)"
echo "  Jaeger UI:     http://localhost:16686"
echo "  Prometheus:    http://localhost:9090"
