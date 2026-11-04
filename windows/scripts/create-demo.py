"""Create a disposable Windows QA library; never point this at a personal library."""
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

destination = Path(sys.argv[1]).resolve()
if (destination / 'meetnotes.sqlite').exists():
    raise SystemExit('Choose a new demo directory; existing libraries are never overwritten.')
destination.mkdir(parents=True, exist_ok=True)
source = Path(__file__).resolve().parents[1] / 'app' / 'src-tauri'
db = sqlite3.connect(destination / 'meetnotes.sqlite')
db.executescript((source / 'schema.sql').read_text(encoding='utf-8'))
db.executescript('''
CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
INSERT INTO grdb_migrations VALUES ('v1'),('v2_folders_tags'),('v3_attachments_live_queries');
ALTER TABLE action_items ADD COLUMN task_ref TEXT;
ALTER TABLE speakers ADD COLUMN voice_samples TEXT NOT NULL DEFAULT '[]';
ALTER TABLE segments ADD COLUMN overlap BOOLEAN NOT NULL DEFAULT 0;
ALTER TABLE meetings ADD COLUMN max_speakers INTEGER;
ALTER TABLE meetings ADD COLUMN expected_speakers INTEGER;
INSERT INTO grdb_migrations VALUES ('v4_task_refs'),('v5_diarization');
''')
now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000')
db.execute("INSERT INTO folders(id,name,created_at) VALUES('project','Keepword',?)", (now,))
db.execute("INSERT INTO templates(id,name,insights_prompt,actions_prompt,is_default,builtin) VALUES('general','General Meeting','List decisions, risks and open questions.','Only explicit commitments, with owners and deadlines.',1,1)")
for identifier, name in [('me', 'Я'), ('alice', 'Алиса')]:
    db.execute("INSERT INTO speakers(id,name,embedding,embedding_model,created_at) VALUES(?,?,'[]','',?)", (identifier, name, now))
for identifier, title, summary, deleted in [
    ('11111111-1111-4111-8111-111111111111', 'Планирование Windows', 'Команда обсудила перенос Keepword на Windows. Алиса подготовит заметки и установщик.', None),
    ('22222222-2222-4222-8222-222222222222', 'Локальный поиск и AI', 'Распознавание, поиск и саммари работают на устройстве.', None),
    ('33333333-3333-4333-8333-333333333333', 'Удалённая заметка', 'Демонстрация корзины.', now),
]:
    db.execute("INSERT INTO meetings(id,title,created_at,status,summary,folder_id,duration,notes,deleted_at) VALUES(?,?,?,'done',?,'project',6.57,'Тестовая библиотека. Личные записи не используются.',?)", (identifier,title,now,summary,deleted))
    (destination/'recordings'/identifier).mkdir(parents=True,exist_ok=True)
meeting='11111111-1111-4111-8111-111111111111'
db.execute("INSERT INTO segments(meeting_id,speaker_id,source,start,end,text) VALUES(?,'alice','system',0,6.57,'We decided to release the Windows application next week. Alice will prepare the meeting notes.')", (meeting,))
db.execute("INSERT INTO segments(meeting_id,speaker_id,source,start,end,text) VALUES(?,'me','mic',0,6,'The meeting starts tomorrow. We will test multilingual semantic search.')", ('22222222-2222-4222-8222-222222222222',))
db.execute("INSERT INTO insights(meeting_id,text,time,sort_order) VALUES(?,'Выпустить приложение на следующей неделе',0,0)", (meeting,))
db.execute("INSERT INTO action_items(meeting_id,text,assignee,created_at) VALUES(?,'Подготовить заметки встречи','Алиса',?)", (meeting,now))
db.execute("INSERT INTO bookmarks(meeting_id,time,label) VALUES(?,2,'Решение о выпуске')", (meeting,))
db.execute("INSERT INTO tags(id,name) VALUES('windows','windows')")
db.execute("INSERT INTO meeting_tags(meeting_id,tag_id) VALUES(?,'windows')", (meeting,))
db.commit()
db.close()
(destination/'settings.json').write_text(json.dumps({'language':'ru','provider':'llama','ggufPath':str(source/'target/test-local-llm/Qwen3.5-4B-Q4_K_M.gguf'),'embeddingSource':'local','autoSummary':False}, ensure_ascii=False), encoding='utf-8')
print(destination)
