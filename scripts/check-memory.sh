#!/usr/bin/env bash
# check-memory.sh
# Verifies the full local Docker Compose stack fits within the
# NFR-PERF-043 budget of 12 GB RAM.
#
# Usage: ./scripts/check-memory.sh
# Run after: docker compose up -d (from docker/compose/)
#
# WHY: NFR-PERF-043 requires the full local stack to consume
# less than 12 GB RAM. This is a solo dev machine constraint.
# If this script fails, services must be profiled and memory
# limits tightened in their docker-compose configurations.

set -euo pipefail

LIMIT_GB=12
LIMIT_BYTES=$((LIMIT_GB * 1024 * 1024 * 1024))

echo "=== StagePass Local Stack Memory Check ==="
echo "Limit: ${LIMIT_GB} GB (NFR-PERF-043)"
echo ""

# Sum RSS memory across all running containers
TOTAL_BYTES=0
while IFS= read -r line; do
  # docker stats returns MiB values like "512MiB / 16GiB"
  USED=$(echo "$line" | awk '{print $1}')
  # Convert to bytes (handles MiB and GiB)
  if [[ "$USED" == *GiB ]]; then
    BYTES=$(echo "$USED" | sed 's/GiB//' | awk '{printf "%d", $1 * 1024 * 1024 * 1024}')
  elif [[ "$USED" == *MiB ]]; then
    BYTES=$(echo "$USED" | sed 's/MiB//' | awk '{printf "%d", $1 * 1024 * 1024}')
  else
    BYTES=0
  fi
  TOTAL_BYTES=$((TOTAL_BYTES + BYTES))
done < <(docker stats --no-stream --format "{{.MemUsage}}" 2>/dev/null | awk -F' / ' '{print $1}')

TOTAL_GB=$(echo "scale=2; $TOTAL_BYTES / 1024 / 1024 / 1024" | bc)

echo "Total memory in use: ${TOTAL_GB} GB"
echo ""

if [ "$TOTAL_BYTES" -gt "$LIMIT_BYTES" ]; then
  echo "❌ FAIL: Stack exceeds ${LIMIT_GB} GB limit (NFR-PERF-043)"
  echo "   Profile containers with: docker stats --no-stream"
  exit 1
else
  echo "✅ PASS: Stack within ${LIMIT_GB} GB limit"
fi