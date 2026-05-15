#!/usr/bin/env bash
# init-labels.sh
# Creates all standard StagePass labels on a target repo.
# Usage: ./scripts/init-labels.sh stagepass-dev/stagepass-docs

set -euo pipefail

REPO="${1:?Usage: init-labels.sh <org/repo>}"

echo "Applying labels to $REPO..."

# Delete GitHub defaults that conflict
gh label delete "good first issue" --repo "$REPO" --yes 2>/dev/null || true
gh label delete "help wanted"      --repo "$REPO" --yes 2>/dev/null || true
gh label delete "invalid"          --repo "$REPO" --yes 2>/dev/null || true
gh label delete "question"         --repo "$REPO" --yes 2>/dev/null || true
gh label delete "wontfix"          --repo "$REPO" --yes 2>/dev/null || true

# ── Work type ───────────────────────────────────────────────
gh label create "feature"     --color "0075CA" --description "New feature or behaviour"        --repo "$REPO" --force
gh label create "bug"         --color "D73A4A" --description "Bug fix"                         --repo "$REPO" --force
gh label create "chore"       --color "E4E669" --description "Tooling, config, cleanup"        --repo "$REPO" --force
gh label create "docs"        --color "0075CA" --description "Documentation only"              --repo "$REPO" --force
gh label create "test"        --color "CFD3D7" --description "Tests only"                      --repo "$REPO" --force
gh label create "ci"          --color "F9D0C4" --description "CI/CD pipeline change"           --repo "$REPO" --force
gh label create "security"    --color "EE0701" --description "Security-related change"         --repo "$REPO" --force
gh label create "performance" --color "E4E669" --description "Performance improvement"         --repo "$REPO" --force

# ── Artifact type ───────────────────────────────────────────
gh label create "artifact:prd"          --color "0052CC" --description "Product Requirements Document"    --repo "$REPO" --force
gh label create "artifact:nfr"          --color "0052CC" --description "Non-Functional Requirements"      --repo "$REPO" --force
gh label create "artifact:adr"          --color "7057FF" --description "Architecture Decision Record"     --repo "$REPO" --force
gh label create "artifact:openapi"      --color "0052CC" --description "OpenAPI specification"            --repo "$REPO" --force
gh label create "artifact:asyncapi"     --color "0052CC" --description "AsyncAPI schema"                  --repo "$REPO" --force
gh label create "artifact:hld"          --color "0052CC" --description "High-Level Design diagram"        --repo "$REPO" --force
gh label create "artifact:threat-model" --color "0052CC" --description "STRIDE threat model"              --repo "$REPO" --force
gh label create "artifact:runbook"      --color "0052CC" --description "Operational runbook"              --repo "$REPO" --force

# ── Phase ───────────────────────────────────────────────────
for i in $(seq 0 10); do
  gh label create "phase-${i}" --color "BFD4F2" --description "Phase ${i}" --repo "$REPO" --force
done

# ── Service ─────────────────────────────────────────────────
SERVICES=(auth "api-gateway" event venue "seat-inventory" booking payment disbursement ticket "check-in" notification waitlist search recommendation chatbot "fraud-detection" analytics all)
for svc in "${SERVICES[@]}"; do
  gh label create "service:${svc}" --color "C2E0C6" --description "Service: ${svc}" --repo "$REPO" --force
done

# ── Status ──────────────────────────────────────────────────
gh label create "status:blocked"        --color "EE0701" --description "Blocked by another issue"      --repo "$REPO" --force
gh label create "status:in-review"      --color "FBCA04" --description "Under review"                  --repo "$REPO" --force
gh label create "status:needs-revision" --color "FBCA04" --description "Needs changes before merging"  --repo "$REPO" --force

echo "✅ Labels applied to $REPO"