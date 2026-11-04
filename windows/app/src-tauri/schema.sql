-- Baseline macOS schema (Store.swift migrations v1…v3), dumped from a GRDB-created library.
-- store.rs applies subsequent macOS migrations to both new and existing libraries.
-- Shadow FTS tables are created by fts5 itself.
CREATE TABLE "meetings" ("id" TEXT PRIMARY KEY NOT NULL, "title" TEXT NOT NULL, "created_at" DATETIME NOT NULL, "duration" DOUBLE NOT NULL DEFAULT 0, "status" TEXT NOT NULL, "summary" TEXT NOT NULL DEFAULT '', "folder_id" TEXT REFERENCES "folders"("id") ON DELETE SET NULL, "template_id" TEXT, "notes" TEXT NOT NULL DEFAULT '', "deleted_at" DATETIME, "modified_at" DATETIME, "event_id" TEXT);
CREATE INDEX "meetings_on_created_at" ON "meetings"("created_at");
CREATE TABLE "speakers" ("id" TEXT PRIMARY KEY NOT NULL, "name" TEXT NOT NULL, "embedding" TEXT NOT NULL, "embedding_model" TEXT NOT NULL, "created_at" DATETIME NOT NULL, "email" TEXT, "company" TEXT, "position" TEXT, "notes" TEXT, "parent_id" TEXT REFERENCES "speakers"("id") ON DELETE SET NULL);
CREATE TABLE "segments" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "speaker_id" TEXT REFERENCES "speakers"("id") ON DELETE SET NULL, "source" TEXT NOT NULL, "start" DOUBLE NOT NULL, "end" DOUBLE NOT NULL, "text" TEXT NOT NULL, "original_text" TEXT, "irrelevant" BOOLEAN NOT NULL DEFAULT 0, "user_edited" BOOLEAN NOT NULL DEFAULT 0);
CREATE INDEX "segments_on_meeting_id" ON "segments"("meeting_id");
CREATE VIRTUAL TABLE "segments_fts" USING fts5(text, tokenize='''porter'' ''unicode61''', content='segments', content_rowid='id');
CREATE TRIGGER "__segments_fts_ai" AFTER INSERT ON "segments" BEGIN
    INSERT INTO "segments_fts"("rowid", "text") VALUES (new."id", new."text");
END;
CREATE TRIGGER "__segments_fts_ad" AFTER DELETE ON "segments" BEGIN
    INSERT INTO "segments_fts"("segments_fts", "rowid", "text") VALUES('delete', old."id", old."text");
END;
CREATE TRIGGER "__segments_fts_au" AFTER UPDATE ON "segments" BEGIN
    INSERT INTO "segments_fts"("segments_fts", "rowid", "text") VALUES('delete', old."id", old."text");
    INSERT INTO "segments_fts"("rowid", "text") VALUES (new."id", new."text");
END;
CREATE VIRTUAL TABLE "meetings_fts" USING fts5(title, summary, tokenize='''porter'' ''unicode61''', content='meetings');
CREATE TRIGGER "__meetings_fts_ai" AFTER INSERT ON "meetings" BEGIN
    INSERT INTO "meetings_fts"("rowid", "title", "summary") VALUES (new."rowid", new."title", new."summary");
END;
CREATE TRIGGER "__meetings_fts_ad" AFTER DELETE ON "meetings" BEGIN
    INSERT INTO "meetings_fts"("meetings_fts", "rowid", "title", "summary") VALUES('delete', old."rowid", old."title", old."summary");
END;
CREATE TRIGGER "__meetings_fts_au" AFTER UPDATE ON "meetings" BEGIN
    INSERT INTO "meetings_fts"("meetings_fts", "rowid", "title", "summary") VALUES('delete', old."rowid", old."title", old."summary");
    INSERT INTO "meetings_fts"("rowid", "title", "summary") VALUES (new."rowid", new."title", new."summary");
END;
CREATE TABLE "folders" ("id" TEXT PRIMARY KEY NOT NULL, "name" TEXT NOT NULL, "icon" TEXT NOT NULL DEFAULT 'folder', "color" TEXT NOT NULL DEFAULT 'blue', "parent_id" TEXT REFERENCES "folders"("id") ON DELETE CASCADE, "template_id" TEXT, "context" TEXT NOT NULL DEFAULT '', "sort_order" INTEGER NOT NULL DEFAULT 0, "created_at" DATETIME NOT NULL);
CREATE TABLE "tags" ("id" TEXT PRIMARY KEY NOT NULL, "name" TEXT NOT NULL UNIQUE COLLATE NOCASE);
CREATE TABLE "meeting_tags" ("meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "tag_id" TEXT NOT NULL REFERENCES "tags"("id") ON DELETE CASCADE, PRIMARY KEY ("meeting_id", "tag_id"));
CREATE INDEX "meeting_tags_on_tag_id" ON "meeting_tags"("tag_id");
CREATE TABLE "insights" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "text" TEXT NOT NULL, "time" DOUBLE, "sort_order" INTEGER NOT NULL);
CREATE INDEX "insights_on_meeting_id" ON "insights"("meeting_id");
CREATE TABLE "action_items" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "text" TEXT NOT NULL, "assignee" TEXT, "due_date" DATETIME, "completed" BOOLEAN NOT NULL DEFAULT 0, "created_at" DATETIME NOT NULL);
CREATE INDEX "action_items_on_meeting_id" ON "action_items"("meeting_id");
CREATE TABLE "bookmarks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "time" DOUBLE NOT NULL, "label" TEXT NOT NULL DEFAULT '');
CREATE INDEX "bookmarks_on_meeting_id" ON "bookmarks"("meeting_id");
CREATE TABLE "chat_sessions" ("id" TEXT PRIMARY KEY NOT NULL, "meeting_id" TEXT REFERENCES "meetings"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "created_at" DATETIME NOT NULL, "updated_at" DATETIME NOT NULL);
CREATE INDEX "chat_sessions_on_meeting_id" ON "chat_sessions"("meeting_id");
CREATE TABLE "chat_messages" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "session_id" TEXT NOT NULL REFERENCES "chat_sessions"("id") ON DELETE CASCADE, "role" TEXT NOT NULL, "content" TEXT NOT NULL, "citations" TEXT NOT NULL DEFAULT '[]', "created_at" DATETIME NOT NULL);
CREATE INDEX "chat_messages_on_session_id" ON "chat_messages"("session_id");
CREATE TABLE "templates" ("id" TEXT PRIMARY KEY NOT NULL, "name" TEXT NOT NULL, "insights_prompt" TEXT NOT NULL, "actions_prompt" TEXT NOT NULL, "is_default" BOOLEAN NOT NULL DEFAULT 0, "builtin" BOOLEAN NOT NULL DEFAULT 0);
CREATE TABLE "chunks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "start" DOUBLE NOT NULL, "end" DOUBLE NOT NULL, "text" TEXT NOT NULL, "embedding" TEXT);
CREATE INDEX "chunks_on_meeting_id" ON "chunks"("meeting_id");
CREATE TABLE "attachments" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "meeting_id" TEXT NOT NULL REFERENCES "meetings"("id") ON DELETE CASCADE, "file_name" TEXT NOT NULL, "file_size" INTEGER NOT NULL, "is_image" BOOLEAN NOT NULL, "recording_time" DOUBLE, "created_at" DATETIME NOT NULL);
CREATE INDEX "attachments_on_meeting_id" ON "attachments"("meeting_id");
CREATE TABLE "saved_queries" ("id" TEXT PRIMARY KEY NOT NULL, "name" TEXT NOT NULL, "prompt" TEXT NOT NULL, "scope_kind" TEXT NOT NULL, "scope_id" TEXT, "period_days" INTEGER NOT NULL, "schedule" TEXT NOT NULL, "hour" INTEGER NOT NULL, "weekday" INTEGER NOT NULL, "session_id" TEXT REFERENCES "chat_sessions"("id") ON DELETE SET NULL, "last_run_at" DATETIME, "next_run_at" DATETIME, "last_status" TEXT, "created_at" DATETIME NOT NULL);
