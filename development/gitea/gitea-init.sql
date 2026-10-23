-- Create the Gitea database and user.
-- Run as a PostgreSQL superuser (e.g. postgres). Use the same password as
-- gitea_password in Vault (homelab/databases/postgres).
-- psql -U postgres -f gitea-init.sql

CREATE USER gitea WITH PASSWORD 'CHANGE_ME';

CREATE DATABASE gitea
    OWNER gitea
    ENCODING 'UTF8'
    LC_COLLATE 'en_US.UTF-8'
    LC_CTYPE 'en_US.UTF-8'
    TEMPLATE template0;

GRANT ALL PRIVILEGES ON DATABASE gitea TO gitea;
