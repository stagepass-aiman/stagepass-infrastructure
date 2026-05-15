# stagepass-infrastructure

Infrastructure-as-code and configuration for the StagePass platform.

## What lives here

| Path | Contents |
|------|----------|
| `/docker/compose/` | Docker Compose files for local full-stack development |
| `/helm/charts/` | Helm chart per service (added just-in-time per phase) |
| `/k8s/namespaces/` | Kubernetes namespace definitions |
| `/k8s/configmaps/` | Non-secret configuration |
| `/terraform/modules/` | Reusable Terraform modules (Phase 9) |
| `/terraform/environments/` | Environment-specific Terraform roots |
| `/observability/prometheus/rules/` | Prometheus alerting rules |
| `/observability/grafana/dashboards/` | Grafana dashboard JSON |
| `/observability/grafana/alerts/` | Grafana alert rules |
| `/observability/loki/` | Loki configuration |
| `/observability/jaeger/` | Jaeger configuration |
| `/scripts/` | Utility scripts (memory check, seed data, smoke tests) |

## Memory Budget

The full local Docker Compose stack must stay under **12 GB RAM** (NFR-PERF-043).

```bash
# After docker compose up -d:
./scripts/check-memory.sh
```

## Rules

- Must remain runnable after every merge (Section 6, system prompt).
- No secrets committed. Values come from HashiCorp Vault or local `.env`
  files that are gitignored.
- Every Helm chart ships with `values-dev.yaml`, `values-staging.yaml`,
  and `values-prod.yaml`.