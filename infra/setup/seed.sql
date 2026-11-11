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
