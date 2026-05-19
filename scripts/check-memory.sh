#!/usr/bin/env bash
# =============================================================================
# check-memory.sh — StagePass Docker stack memory verification
#
# Repo: stagepass-infrastructure
# Path: /scripts/check-memory.sh
#
# PURPOSE:
#   Verify that the running Docker Compose stack does not exceed the
#   NFR-PERF-043 hard limit of 12 GB total memory.
#   This script is run:
#     1. Manually after docker compose up to verify budget compliance
#     2. In CI after each service phase is introduced (Phase 3, 4, 5)
#     3. During Phase 7 quality gates as a pre-merge check
#
# USAGE:
#   ./scripts/check-memory.sh [--warn-threshold-gb N] [--fail-threshold-gb N]
#
#   Options:
#     --warn-threshold-gb N    Warn if total exceeds N GB (default: 10)
#     --fail-threshold-gb N    Fail if total exceeds N GB (default: 12)
#     --json                   Output results as JSON (for CI integration)
#     --wait N                 Wait N seconds for containers to stabilise
#                              before measuring (default: 30)
#
# EXIT CODES:
#   0  — All containers within budget
#   1  — Total stack exceeds FAIL threshold (12 GB by default)
#   2  — One or more containers exceed their individual budget (ADR-002 §3.6)
#   3  — No running stagepass containers found
#
# INDIVIDUAL BUDGETS (ADR-002 §3.6, NFR §5.4):
#   Java T1 services (Auth, Seat, Booking, Disbursement):  512 MB each
#   Java T1 service (Payment — Quarkus):                   512 MB each
#   Java T2 service (API Gateway):                         384 MB
#   Node services (Event, Venue, Ticket, Check-in,
#                  Notification, Waitlist):                 256 MB each
#   Python services (Search, Recommendation, Chatbot,
#                    Fraud, Analytics):                     384 MB each
#   PostgreSQL:                                            512 MB
#   MongoDB:                                               512 MB
#   Redis:                                                 256 MB
#   Kafka:                                                 384 MB
#   ZooKeeper:                                             256 MB
#   Elasticsearch:                                         512 MB
#   ClickHouse:                                            256 MB
#   Qdrant:                                                256 MB
#   MinIO:                                                 128 MB
#   Vault:                                                 128 MB
#   Prometheus:                                            256 MB
#   Grafana:                                               256 MB
#   Loki:                                                  256 MB
#   Promtail:                                               64 MB
#   Jaeger:                                                256 MB
#   OTel Collector:                                        128 MB
#   Exporters (×8):                                         32 MB each
# =============================================================================

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
WARN_THRESHOLD_GB=10
FAIL_THRESHOLD_GB=12
OUTPUT_JSON=false
WAIT_SECONDS=30
COMPOSE_PROJECT="stagepass"

# ─── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --warn-threshold-gb) WARN_THRESHOLD_GB="$2"; shift 2 ;;
    --fail-threshold-gb) FAIL_THRESHOLD_GB="$2"; shift 2 ;;
    --json)              OUTPUT_JSON=true; shift ;;
    --wait)              WAIT_SECONDS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Per-container memory budgets (MiB) ──────────────────────────────────────
# Key: container name prefix (matched with grep)
# Value: budget in MiB
declare -A BUDGETS=(
  # Infrastructure
  ["stagepass-postgres"]=512
  ["stagepass-mongodb"]=512
  ["stagepass-redis"]=256
  ["stagepass-kafka"]=384
  ["stagepass-zookeeper"]=256
  ["stagepass-elasticsearch"]=512
  ["stagepass-clickhouse"]=256
  ["stagepass-qdrant"]=256
  ["stagepass-minio"]=128
  ["stagepass-vault"]=128
  ["stagepass-kafka-init"]=256
  # Observability
  ["stagepass-prometheus"]=256
  ["stagepass-grafana"]=256
  ["stagepass-loki"]=256
  ["stagepass-promtail"]=64
  ["stagepass-jaeger"]=256
  ["stagepass-otel-collector"]=128
  # Exporters
  ["stagepass-pg-exporter"]=64
  ["stagepass-mongodb-exporter"]=32
  ["stagepass-redis-exporter"]=32
  ["stagepass-kafka-exporter"]=32
  ["stagepass-es-exporter"]=32
  # Application services (Phase 3+)
  ["auth-service"]=512
  ["seat-inventory-service"]=512
  ["booking-service"]=512
  ["payment-service"]=512
  ["disbursement-service"]=512
  ["api-gateway"]=384
  ["event-service"]=256
  ["venue-service"]=256
  ["ticket-service"]=256
  ["check-in-service"]=256
  ["notification-service"]=256
  ["waitlist-service"]=256
  ["search-service"]=384
  ["recommendation-service"]=384
  ["chatbot-service"]=384
  ["fraud-detection-service"]=384
  ["analytics-service"]=384
  # SonarQube (ci profile only — excluded from total when not running)
  ["stagepass-sonarqube"]=1024
  ["stagepass-sonarqube-postgres"]=256
)

FAIL_THRESHOLD_MIB=$(python -c "print(int(${FAIL_THRESHOLD_GB} * 1024))")
WARN_THRESHOLD_MIB=$(python -c "print(int(${WARN_THRESHOLD_GB} * 1024))")

# ─── Wait for containers to stabilise ────────────────────────────────────────
if [[ "${WAIT_SECONDS}" -gt 0 ]]; then
  echo "⏳ Waiting ${WAIT_SECONDS}s for containers to stabilise..."
  sleep "${WAIT_SECONDS}"
fi

# ─── Collect running stagepass containers ────────────────────────────────────
echo "📊 Collecting memory usage for project '${COMPOSE_PROJECT}'..."

CONTAINER_LIST=$(docker ps \
  --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
  --format "{{.Names}}" 2>/dev/null)

if [[ -z "${CONTAINER_LIST}" ]]; then
  echo "❌ No running containers found for project '${COMPOSE_PROJECT}'."
  echo "   Run: docker compose --profile infra up -d"
  exit 3
fi

# ─── Measure memory usage ────────────────────────────────────────────────────
declare -a RESULTS=()
TOTAL_MIB=0
BUDGET_VIOLATIONS=0

# docker stats output format: "container_name MiB / limit"
# We parse the usage column only.
while IFS= read -r container; do
  STATS=$(docker stats --no-stream --format "{{.MemUsage}}" "${container}" 2>/dev/null || echo "0MiB / 0MiB")

  # Parse "123.4MiB / 512MiB" or "1.2GiB / 2GiB"
  USAGE_RAW=$(echo "${STATS}" | awk '{print $1}')

  # Convert to MiB
  if echo "${USAGE_RAW}" | grep -qi "gib"; then
    USAGE_MIB=$(echo "${USAGE_RAW}" | sed 's/GiB//i' | awk '{printf "%.0f", $1 * 1024}')
  elif echo "${USAGE_RAW}" | grep -qi "mib"; then
    USAGE_MIB=$(echo "${USAGE_RAW}" | sed 's/MiB//i' | awk '{printf "%.0f", $1}')
  elif echo "${USAGE_RAW}" | grep -qi "kib"; then
    USAGE_MIB=$(echo "${USAGE_RAW}" | sed 's/KiB//i' | awk '{printf "%.0f", $1 / 1024}')
  else
    USAGE_MIB=0
  fi

  TOTAL_MIB=$((TOTAL_MIB + USAGE_MIB))

  # Check individual budget
  BUDGET_MIB=0
  OVER_BUDGET="no"
  for key in "${!BUDGETS[@]}"; do
    if echo "${container}" | grep -qi "${key}"; then
      BUDGET_MIB=${BUDGETS[$key]}
      if [[ "${USAGE_MIB}" -gt "${BUDGET_MIB}" ]]; then
        OVER_BUDGET="yes"
        BUDGET_VIOLATIONS=$((BUDGET_VIOLATIONS + 1))
      fi
      break
    fi
  done

  STATUS_ICON="✅"
  if [[ "${OVER_BUDGET}" == "yes" ]]; then
    STATUS_ICON="⚠️ OVER BUDGET"
  fi

  RESULTS+=("${container}|${USAGE_MIB}|${BUDGET_MIB}|${OVER_BUDGET}|${STATUS_ICON}")
done <<< "${CONTAINER_LIST}"

# ─── Output ──────────────────────────────────────────────────────────────────
TOTAL_GB=$(python -c "print(f'{${TOTAL_MIB}/1024:.2f}')")

if [[ "${OUTPUT_JSON}" == "true" ]]; then
  # JSON output for CI
  echo "{"
  echo "  \"total_mib\": ${TOTAL_MIB},"
  echo "  \"total_gb\": ${TOTAL_GB},"
  echo "  \"warn_threshold_gb\": ${WARN_THRESHOLD_GB},"
  echo "  \"fail_threshold_gb\": ${FAIL_THRESHOLD_GB},"
  echo "  \"budget_violations\": ${BUDGET_VIOLATIONS},"
  echo "  \"containers\": ["
  FIRST=true
  for result in "${RESULTS[@]}"; do
    IFS='|' read -r name mib budget over status <<< "${result}"
    [[ "${FIRST}" == "true" ]] && FIRST=false || echo ","
    printf '    {"name": "%s", "usage_mib": %s, "budget_mib": %s, "over_budget": %s}' \
      "${name}" "${mib}" "${budget}" "$([ "${over}" == "yes" ] && echo true || echo false)"
  done
  echo ""
  echo "  ]"
  echo "}"
else
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║           StagePass — Docker Stack Memory Usage Report              ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  printf "║  %-45s  %8s  %8s  %-10s║\n" "Container" "Used" "Budget" "Status"
  echo "╠══════════════════════════════════════════════════════════════════════╣"

  for result in "${RESULTS[@]}"; do
    IFS='|' read -r name mib budget over status <<< "${result}"
    BUDGET_STR="${budget} MiB"
    [[ "${budget}" -eq 0 ]] && BUDGET_STR="(unknown)"
    printf "║  %-45s  %5s MiB  %-8s  %-10s║\n" \
      "$(echo "${name}" | cut -c1-45)" "${mib}" "${BUDGET_STR}" "${status}"
  done

  echo "╠══════════════════════════════════════════════════════════════════════╣"
  printf "║  %-45s  %5s MiB  %-19s║\n" "TOTAL" "${TOTAL_MIB}" "(${TOTAL_GB} GB)"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  printf "║  %-45s  %5s MiB                      ║\n" "Warn threshold" "${WARN_THRESHOLD_MIB}"
  printf "║  %-45s  %5s MiB  (NFR-PERF-043)       ║\n" "Hard limit (FAIL threshold)" "${FAIL_THRESHOLD_MIB}"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
fi

# ─── Exit code determination ─────────────────────────────────────────────────
HEADROOM_MIB=$((FAIL_THRESHOLD_MIB - TOTAL_MIB))

if [[ "${TOTAL_MIB}" -gt "${FAIL_THRESHOLD_MIB}" ]]; then
  echo "❌ FAIL: Total stack memory (${TOTAL_MIB} MiB / ${TOTAL_GB} GB) exceeds"
  echo "   NFR-PERF-043 hard limit of ${FAIL_THRESHOLD_GB} GB."
  echo "   This is a CI-blocking condition. Reduce service memory allocations."
  exit 1
fi

if [[ "${BUDGET_VIOLATIONS}" -gt 0 ]]; then
  echo "⚠️  WARN: ${BUDGET_VIOLATIONS} container(s) exceed their individual ADR-002 §3.6 budget."
  echo "   Total is within the 12 GB ceiling but individual allocations are over."
  echo "   Check -Xmx / --max-old-space-size / GOMEMLIMIT settings per service."
  exit 2
fi

if [[ "${TOTAL_MIB}" -gt "${WARN_THRESHOLD_MIB}" ]]; then
  echo "⚠️  WARN: Total stack memory (${TOTAL_GB} GB) approaching the ${FAIL_THRESHOLD_GB} GB limit."
  echo "   Headroom: ${HEADROOM_MIB} MiB. Monitor before adding more services."
fi

echo "✅ PASS: Total stack memory = ${TOTAL_GB} GB / ${FAIL_THRESHOLD_GB} GB limit."
echo "   Headroom: ${HEADROOM_MIB} MiB. NFR-PERF-043 satisfied."
exit 0