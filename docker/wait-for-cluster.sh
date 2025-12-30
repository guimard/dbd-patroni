#!/bin/bash
set -e

echo "Waiting for Patroni cluster to be ready..."

MAX_ATTEMPTS=60
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    echo "Attempt $ATTEMPT/$MAX_ATTEMPTS..."

    # Try each Patroni endpoint
    for url in $(echo $PATRONI_URLS | tr ',' ' '); do
        RESPONSE=$(curl -s "$url" 2>/dev/null || echo "{}")

        # Check if we have a leader (use name as hostname since they're on the same docker network)
        LEADER_NAME=$(echo "$RESPONSE" | jq -r '.members[]? | select(.role == "leader") | .name' 2>/dev/null || echo "")

        if [ -n "$LEADER_NAME" ]; then
            echo "Found leader: $LEADER_NAME"

            # Count running or streaming members
            RUNNING=$(echo "$RESPONSE" | jq -r '[.members[]? | select(.state == "running" or .state == "streaming")] | length' 2>/dev/null || echo "0")

            if [ "$RUNNING" -ge 2 ]; then
                echo "Cluster is ready with $RUNNING running members"

                # Wait a bit more for database initialization
                sleep 2

                # Check if we can connect to postgres (basic connectivity) using the leader name as DNS
                if PGPASSWORD=postgres psql -h "$LEADER_NAME" -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
                    echo "PostgreSQL is accessible"

                    # Check if testdb exists, create it if not
                    DB_EXISTS=$(PGPASSWORD=postgres psql -h "$LEADER_NAME" -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'" 2>/dev/null || echo "")

                    if [ "$DB_EXISTS" != "1" ]; then
                        echo "Creating test database and user..."
                        PGPASSWORD=postgres psql -h "$LEADER_NAME" -U postgres -d postgres <<-EOSQL
                            CREATE USER $PGUSER WITH PASSWORD '$PGPASSWORD';
                            CREATE DATABASE $PGDATABASE OWNER $PGUSER;
EOSQL
                        PGPASSWORD=postgres psql -h "$LEADER_NAME" -U postgres -d "$PGDATABASE" <<-EOSQL
                            CREATE TABLE IF NOT EXISTS users (
                                id SERIAL PRIMARY KEY,
                                name VARCHAR(100) NOT NULL,
                                created_at TIMESTAMP DEFAULT NOW()
                            );
                            GRANT ALL PRIVILEGES ON TABLE users TO $PGUSER;
                            GRANT USAGE, SELECT ON SEQUENCE users_id_seq TO $PGUSER;

                            CREATE TABLE IF NOT EXISTS logs (
                                id SERIAL PRIMARY KEY,
                                message TEXT,
                                created_at TIMESTAMP DEFAULT NOW()
                            );
                            GRANT ALL PRIVILEGES ON TABLE logs TO $PGUSER;
                            GRANT USAGE, SELECT ON SEQUENCE logs_id_seq TO $PGUSER;
EOSQL
                        echo "Test database created"
                    fi

                    # Verify database is accessible with test user
                    if PGPASSWORD=$PGPASSWORD psql -h "$LEADER_NAME" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1" >/dev/null 2>&1; then
                        echo "Database is accessible"
                        exit 0
                    else
                        echo "Database not yet accessible with test user, waiting..."
                    fi
                else
                    echo "PostgreSQL not yet accessible, waiting..."
                fi
            else
                echo "Only $RUNNING member(s) running, need at least 2..."
            fi
        fi
    done

    sleep 2
done

echo "Timeout waiting for cluster"
exit 1
