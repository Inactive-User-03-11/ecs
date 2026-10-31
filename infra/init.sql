CREATE TABLE IF NOT EXISTS calls (id BIGSERIAL PRIMARY KEY, account_id TEXT NOT NULL, disposition TEXT, attempt INT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (account_id, attempt))
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN CREATE USER app_user; END IF; END $$
GRANT rds_iam TO app_user
GRANT SELECT, INSERT ON calls TO app_user
GRANT USAGE, SELECT ON SEQUENCE calls_id_seq TO app_user