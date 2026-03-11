-- Create additional databases on issuer-postgres for shared services
-- This runs only on first initialization (empty data directory)

-- BDRS Server database
CREATE USER bdrs WITH PASSWORD 'bdrs';
CREATE DATABASE bdrs OWNER bdrs;
GRANT ALL PRIVILEGES ON DATABASE bdrs TO bdrs;
