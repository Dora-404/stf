BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION hash_sha256(input_text TEXT)
RETURNS BYTEA
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT digest(input_text, 'sha256');
$$;

CREATE TABLE IF NOT EXISTS users (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    password_hash BYTEA NOT NULL,
    role INTEGER NOT NULL,
    last_auth_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS checklists (
    id BIGSERIAL PRIMARY KEY,
    name TEXT,
    title TEXT,
    description TEXT NOT NULL,
    author_id BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    is_hidden BOOLEAN NOT NULL DEFAULT FALSE,
    is_public BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_checklists_author_title UNIQUE (author_id, title)
);

-- Триггер для синхронизации name и title
CREATE OR REPLACE FUNCTION sync_checklists_name_title() RETURNS trigger AS $$
BEGIN
    IF NEW.name IS NULL THEN
        NEW.name := NEW.title;
    END IF;
    IF NEW.title IS NULL THEN
        NEW.title := NEW.name;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_checklists_name_title
BEFORE INSERT OR UPDATE ON checklists
FOR EACH ROW EXECUTE FUNCTION sync_checklists_name_title();

CREATE TABLE IF NOT EXISTS checklist_questions (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    type INTEGER NOT NULL,
    possible_answers JSONB,
    checklist_id BIGINT NOT NULL REFERENCES checklists(id) ON DELETE CASCADE,
    CONSTRAINT uq_checklist_questions_name UNIQUE (checklist_id, name)
);

CREATE TABLE IF NOT EXISTS checklist_answers (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    checklist_id BIGINT NOT NULL REFERENCES checklists(id) ON DELETE CASCADE,
    answers JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_files (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_user_files_name UNIQUE (user_id, filename)
);

INSERT INTO users (name, email, password_hash, role, last_auth_at)
VALUES (
    'CyberBabka',
    'babka@babka.babka',
    hash_sha256(gen_random_uuid()::text),
    1,
    now()
)
ON CONFLICT (email) DO UPDATE SET password_hash = hash_sha256(gen_random_uuid()::text);

COMMIT;
