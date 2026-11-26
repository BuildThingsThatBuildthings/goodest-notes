CREATE TABLE IF NOT EXISTS projects (id uuid PRIMARY KEY, title text NOT NULL, rules text NOT NULL DEFAULT '', catalog_id text);
CREATE TABLE IF NOT EXISTS records (id text PRIMARY KEY, kind text NOT NULL, body jsonb NOT NULL, rev int NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS members (project uuid REFERENCES projects, record text REFERENCES records, PRIMARY KEY(project,record));
CREATE TABLE IF NOT EXISTS conflicts (id uuid PRIMARY KEY, project uuid REFERENCES projects, record text REFERENCES records, actor text NOT NULL, proposed jsonb NOT NULL, base int NOT NULL, created timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS messages (seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, id uuid UNIQUE NOT NULL, project uuid REFERENCES projects NOT NULL, author text NOT NULL, body text NOT NULL, anchor text, reply uuid REFERENCES messages(id), task uuid, created timestamptz DEFAULT now());
CREATE INDEX IF NOT EXISTS project_messages ON messages(project,seq);
CREATE TABLE IF NOT EXISTS receipts (actor text, project uuid, id uuid, request text NOT NULL, response jsonb NOT NULL, PRIMARY KEY(actor,project,id));
CREATE TABLE IF NOT EXISTS codes (hash text PRIMARY KEY, client text NOT NULL, redirect text NOT NULL, challenge text NOT NULL, project uuid REFERENCES projects NOT NULL, expires timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS grants (id uuid PRIMARY KEY, access_hash text UNIQUE NOT NULL, refresh_hash text UNIQUE NOT NULL, client text NOT NULL, project uuid REFERENCES projects NOT NULL, expires timestamptz NOT NULL, refresh_expires timestamptz NOT NULL, revoked boolean NOT NULL DEFAULT false);
CREATE TABLE IF NOT EXISTS settings (id int PRIMARY KEY CHECK (id=1), main text NOT NULL);
INSERT INTO settings VALUES (1,'claude-opus-5-5') ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS tasks (id uuid PRIMARY KEY, project uuid REFERENCES projects NOT NULL, brief text NOT NULL, anchor text, state text NOT NULL, stage int NOT NULL DEFAULT 0, models jsonb NOT NULL, history jsonb NOT NULL DEFAULT '[]', lease uuid, lease_until timestamptz, created timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS spend (id uuid PRIMARY KEY, month text NOT NULL, provider text NOT NULL, reserved bigint NOT NULL CHECK(reserved>=0), charged bigint CHECK(charged>=0), created timestamptz DEFAULT now());
CREATE INDEX IF NOT EXISTS spend_month ON spend(month,provider);

CREATE TABLE IF NOT EXISTS visuals(id uuid PRIMARY KEY, signature text NOT NULL, reservation uuid REFERENCES spend, result jsonb);
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS snapshot jsonb;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS target text;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS base int;
CREATE TABLE IF NOT EXISTS chunks(hash text PRIMARY KEY, bytes bytea NOT NULL);

-- Only the application database owner accesses these tables. Hosted services
-- that expose a public REST schema must not expose rows to anonymous clients.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['projects','records','members','conflicts','messages','receipts','codes','grants','settings','tasks','spend','visuals','chunks'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('REVOKE ALL ON TABLE %I FROM PUBLIC',t);
    IF EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN EXECUTE format('REVOKE ALL ON TABLE %I FROM anon',t); END IF;
    IF EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN EXECUTE format('REVOKE ALL ON TABLE %I FROM authenticated',t); END IF;
  END LOOP;
END $$;
