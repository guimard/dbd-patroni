#!/bin/bash
set -e

# Update pg_hba.conf to allow connections from Docker network without SSL
# This is needed for integration tests
PG_HBA=$(psql -U postgres -t -c "SHOW hba_file")
echo "Updating $PG_HBA to allow testuser connections..."

# Add rule for testuser from all hosts with md5 authentication
echo "host testdb testuser 0.0.0.0/0 md5" >> "$PG_HBA"
echo "host testdb testuser ::/0 md5" >> "$PG_HBA"

# Reload PostgreSQL configuration
psql -U postgres -c "SELECT pg_reload_conf();"

# Create test user and database
psql -U postgres <<-EOSQL
    CREATE USER testuser PASSWORD 'testpass';
    CREATE DATABASE testdb OWNER testuser;
EOSQL

# Create test tables
psql -U postgres -d testdb <<-EOSQL
    CREATE TABLE users (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        created_at TIMESTAMP DEFAULT NOW()
    );
    GRANT ALL PRIVILEGES ON TABLE users TO testuser;
    GRANT USAGE, SELECT ON SEQUENCE users_id_seq TO testuser;

    CREATE TABLE logs (
        id SERIAL PRIMARY KEY,
        message TEXT,
        created_at TIMESTAMP DEFAULT NOW()
    );
    GRANT ALL PRIVILEGES ON TABLE logs TO testuser;
    GRANT USAGE, SELECT ON SEQUENCE logs_id_seq TO testuser;
EOSQL
