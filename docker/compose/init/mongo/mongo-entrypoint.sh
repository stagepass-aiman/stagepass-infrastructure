#!/bin/bash
set -e

openssl rand -base64 756 > /tmp/mongo-keyfile
chmod 400 /tmp/mongo-keyfile
chown 999:999 /tmp/mongo-keyfile

(
  echo "[rs-init] Waiting for mongod to accept connections..."
  until mongosh --host 127.0.0.1 --quiet \
    -u "$MONGO_INITDB_ROOT_USERNAME" \
    -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1; do
    sleep 2
  done
  echo "[rs-init] mongod ready. Initiating rs0..."
  mongosh --host 127.0.0.1 --quiet \
    -u "$MONGO_INITDB_ROOT_USERNAME" \
    -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval 'try{rs.status();print("rs0 already initialised")}catch(e){rs.initiate({_id:"rs0",members:[{_id:0,host:"mongodb:27017"}]});print("rs0 initialised")}'
) &

exec /usr/local/bin/docker-entrypoint.sh mongod --replSet rs0 --bind_ip_all --keyFile /tmp/mongo-keyfile