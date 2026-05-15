#!/usr/bin/env bash
# init-milestones.sh
# Usage: ./scripts/init-milestones.sh stagepass-dev/stagepass-docs

set -euo pipefail

REPO="${1:?Usage: init-milestones.sh <org/repo>}"

MILESTONES=(
  "Phase 0 — Foundation"
  "Phase 1 — Design"
  "Phase 2 — Infrastructure"
  "Phase 3 — Auth + Event"
  "Phase 4 — Core Services"
  "Phase 5 — AI/ML"
  "Phase 6 — Frontend"
  "Phase 7 — Quality"
  "Phase 8 — CI/CD"
  "Phase 9 — Cloud"
  "Phase 10 — Polish"
)

for ms in "${MILESTONES[@]}"; do
  gh api repos/$REPO/milestones \
    --method POST \
    --field title="$ms" \
    --field state="open" \
    2>/dev/null && echo "Created: $ms" || echo "Skipped (may exist): $ms"
done

echo "✅ Milestones applied to $REPO"