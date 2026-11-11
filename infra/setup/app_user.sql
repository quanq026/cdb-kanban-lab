-- Creates the app_user role with least privileges for CDB Kanban.
-- Usage:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v app_user_password='<password>' -f infra/setup/app_user.sql

\if :{?app_user_password}
\else
  \set app_user_password 'change_me_app_password'
\endif

DO $do$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user LOGIN;
    END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO app_user', current_database());
END
$do$;

ALTER ROLE app_user WITH PASSWORD :'app_user_password';
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON users, tasks TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;
