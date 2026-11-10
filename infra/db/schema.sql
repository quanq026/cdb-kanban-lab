CREATE TABLE users (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         text NOT NULL UNIQUE,
    password_hash text
);

CREATE TABLE tasks (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users(id),
    title   text NOT NULL CHECK (length(btrim(title)) > 0),
    status  text NOT NULL DEFAULT 'todo' CHECK (status IN ('todo', 'doing', 'done'))
);

CREATE INDEX idx_tasks_user_status ON tasks (user_id, status);

INSERT INTO users (email) VALUES
    ('an@example.test'),
    ('binh@example.test');

INSERT INTO tasks (user_id, title, status)
SELECT u.id, s.title, s.status
FROM (VALUES
    ('an@example.test',   'Soạn đề cương báo cáo',      'todo'),
    ('an@example.test',   'Nộp bài tập tuần 3',         'doing'),
    ('an@example.test',   'Cài PostgreSQL 17',          'done'),
    ('binh@example.test', 'Chuẩn bị slide demo',        'todo'),
    ('binh@example.test', 'Kiểm thử backup/restore',    'doing')
) AS s(email, title, status)
JOIN users u ON u.email = s.email;
