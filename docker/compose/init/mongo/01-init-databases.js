// =============================================================================
// mongo-init.js — Per-service database and user provisioning
//
// WHY THIS EXISTS:
//   Same isolation principle as postgres-init.sh but for MongoDB.
//   Each service user is created with 'readWrite' role scoped to its
//   own database only. MongoDB's role-based access control (RBAC)
//   prevents a user created on 'event_db' from reading 'venue_db' —
//   the mongod process enforces this at the authentication layer.
//
// SERVICES USING MONGODB (ADR-002 §3.2):
//   - Event Service   → event_db      (heterogeneous event schemas,
//                                      seating configs, Decimal128 prices)
//   - Venue Service   → venue_db      (nested layout documents, versioned)
//   - Booking Service → booking_read_db (CQRS read model — denormalised
//                                       booking + ticket + split in one doc)
//
// NOTE: This script runs as the MongoDB root user during container init.
// After this runs, the root credential is not used by any service.
// =============================================================================

// Event Service database
db = db.getSiblingDB('event_db');
db.createUser({
  user: 'event_user',
  pwd:  process.env.MONGO_EVENT_PASSWORD,
  roles: [{ role: 'readWrite', db: 'event_db' }]
});
// Create a sentinel collection so the database exists and is visible in tooling
db.createCollection('_init');
print('[mongo-init] event_db ready for event_user');

// Venue Service database
db = db.getSiblingDB('venue_db');
db.createUser({
  user: 'venue_user',
  pwd:  process.env.MONGO_VENUE_PASSWORD,
  roles: [{ role: 'readWrite', db: 'venue_db' }]
});
db.createCollection('_init');
print('[mongo-init] venue_db ready for venue_user');

// Booking Service CQRS read model
// NOTE: booking_user (Postgres) is the write-side owner.
// booking_read_user is a separate identity for the MongoDB read model.
// The Booking Service uses TWO separate connection pools — one to PostgreSQL
// (write model, SERIALIZABLE) and one to MongoDB (read model, eventual).
// These are distinct credentials to make this explicit.
db = db.getSiblingDB('booking_read_db');
db.createUser({
  user: 'booking_read_user',
  pwd:  process.env.MONGO_BOOKING_READ_PASSWORD,
  roles: [{ role: 'readWrite', db: 'booking_read_db' }]
});
db.createCollection('_init');
print('[mongo-init] booking_read_db ready for booking_read_user');

print('[mongo-init] All MongoDB service databases provisioned.');
print('[mongo-init] Isolation: each user has readWrite only on its own database.');