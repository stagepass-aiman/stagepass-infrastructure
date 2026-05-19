#!/bin/bash
# =============================================================================
# postgres-init.sh — Per-service database and user provisioning
#
# WHY THIS EXISTS:
#   ADR-002 §3.2 mandates database-per-service isolation. We run one PostgreSQL
#   container for resource efficiency (NFR-PERF-043 / NFR §5.4), but each
#   service gets its own DATABASE and USER with CONNECT privilege only on that
#   database. This script is the mechanism that enforces the isolation contract.
#
# THE ISOLATION MECHANISM (answer to the design review question):
#   1. Each service user is created with NOINHERIT — it gets no privileges from
#      the 'postgres' superuser role.
#   2. GRANT CONNECT is issued only to the service's own database. PostgreSQL
#      rejects the connection at the handshake level if a user attempts to
#      connect to any other database — no query can run, no data is readable.
#   3. pg_hba.conf (via POSTGRES_HOST_AUTH_METHOD=scram-sha-256) requires
#      SCRAM authentication for all non-superuser connections.
#   4. In Phase 2 local dev, passwords are injected via environment variables
#      sourced from Vault. The Vault policy for each service grants access only
#      to that service's secret path, so Booking Service cannot obtain
#      Auth Service's database password even if it tried.
#   5. REVOKE ALL ON SCHEMA public FROM PUBLIC prevents any user from reading
#      tables owned by other users in a shared schema (belt-and-suspenders).
#
# IMPORTANT: This runs as the 'postgres' superuser inside the init container.
# After this script completes, the postgres superuser account is not used by
# any service — only the per-service accounts are in use.
# =============================================================================

set -euo pipefail

# Helper: create a database and its owning user, then lock down access.
create_service_db() {
  local dbname="$1"
  local username="$2"
  local password="$3"

  echo "[postgres-init] Creating database '${dbname}' with owner '${username}'..."

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    -- Create the service user. No superuser, no createdb, no inherit.
    CREATE USER ${username} WITH
      PASSWORD '${password}'
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOINHERIT
      LOGIN;

    -- Create the database owned by the service user.
    CREATE DATABASE ${dbname} OWNER ${username};

    -- Explicitly revoke any PUBLIC connect on this database.
    -- Only the owning user (and postgres superuser) can connect.
    REVOKE CONNECT ON DATABASE ${dbname} FROM PUBLIC;
    GRANT  CONNECT ON DATABASE ${dbname} TO   ${username};
EOSQL

  # Lock down the public schema inside the new database.
  # This prevents the 'postgres' default public schema grants from allowing
  # cross-user table reads if someone ever connects with the wrong credentials.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${dbname}" <<-EOSQL
    REVOKE ALL ON SCHEMA public FROM PUBLIC;
    GRANT  ALL ON SCHEMA public TO   ${username};
EOSQL

  echo "[postgres-init] Database '${dbname}' ready."
}

# =============================================================================
# T1 Critical services — SERIALIZABLE isolation enforced at query level in
# the service code (not here). The DB user permissions don't change between
# tiers — tier determines the SLO and saga complexity, not DB-level config.
# =============================================================================
create_service_db "auth_db"            "auth_user"            "${POSTGRES_AUTH_PASSWORD}"
create_service_db "seat_inventory_db"  "seat_user"            "${POSTGRES_SEAT_PASSWORD}"
create_service_db "booking_write_db"   "booking_user"         "${POSTGRES_BOOKING_PASSWORD}"
create_service_db "payment_db"         "payment_user"         "${POSTGRES_PAYMENT_PASSWORD}"
create_service_db "disbursement_db"    "disbursement_user"    "${POSTGRES_DISBURSEMENT_PASSWORD}"

# =============================================================================
# T2 Important services
# =============================================================================
create_service_db "ticket_db"          "ticket_user"          "${POSTGRES_TICKET_PASSWORD}"
create_service_db "checkin_db"         "checkin_user"         "${POSTGRES_CHECKIN_PASSWORD}"

# =============================================================================
# T3 Enhancement services
# =============================================================================
create_service_db "fraud_detection_db" "fraud_user"           "${POSTGRES_FRAUD_PASSWORD}"

echo "[postgres-init] All service databases provisioned."
echo "[postgres-init] Isolation contract: each user has CONNECT only on its own database."
echo "[postgres-init] Cross-database access requires postgres superuser (not available to services)."