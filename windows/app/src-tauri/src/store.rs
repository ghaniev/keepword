//! SQLite library, same file format as the macOS app (Store.swift, GRDB).
//! Dates are GRDB's text format, "YYYY-MM-DD HH:MM:SS.SSS" in UTC, made by SQLite's strftime.

use rusqlite::{params, Connection};
use serde::Serialize;
use std::path::{Path, PathBuf};

/// The baseline dump contains v1–v3. Later migrations keep the same ids and SQL as macOS.
const MIGRATIONS: [&str; 3] = ["v1", "v2_folders_tags", "v3_attachments_live_queries"];
const UPGRADES: [(&str, &str); 2] = [
    (
        "v4_task_refs",
        "ALTER TABLE action_items ADD COLUMN task_ref TEXT;",
    ),
    (
        "v5_diarization",
        "ALTER TABLE speakers ADD COLUMN voice_samples TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE segments ADD COLUMN overlap BOOLEAN NOT NULL DEFAULT 0;
        ALTER TABLE meetings ADD COLUMN max_speakers INTEGER;
        ALTER TABLE meetings ADD COLUMN expected_speakers INTEGER;",
    ),
];
const NOW: &str = "strftime('%Y-%m-%d %H:%M:%f', 'now')";

pub struct Store {
    pub db: Connection,
    pub dir: PathBuf,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Meeting {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub duration: f64,
    pub status: String,
    pub summary: String,
    pub folder_id: Option<String>,
}

impl Store {
    pub fn open(dir: &Path) -> rusqlite::Result<Store> {
        let db = Connection::open(dir.join("meetnotes.sqlite"))?;
        db.execute_batch("PRAGMA foreign_keys = ON; CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);")?;
        // Libraries from 0.1.0 recorded the v2 migration under an earlier name.
        db.execute(
            "UPDATE grdb_migrations SET identifier = ?1 WHERE identifier LIKE 'v2!_%' ESCAPE '!' AND identifier <> ?1",
            [MIGRATIONS[1]],
        )?;
        let identifiers = db
            .prepare("SELECT identifier FROM grdb_migrations")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        if identifiers.iter().any(|id| {
            !MIGRATIONS.contains(&id.as_str()) && !UPGRADES.iter().any(|(known, _)| known == id)
        }) {
            return Err(rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_ERROR),Some("This library was created by a newer Keepword version. Update the Windows app before opening it.".into())));
        }
        let applied: i64 =
            db.query_row("SELECT count(*) FROM grdb_migrations", [], |r| r.get(0))?;
        if applied == 0 {
            let tx = db.unchecked_transaction()?;
            tx.execute_batch(include_str!("../schema.sql"))?;
            tx.execute(&format!("INSERT INTO speakers VALUES ('me', 'Me', '[]', '', {NOW}, NULL, NULL, NULL, NULL, NULL)"), [])?;
            for (i, (id, name, insights, actions)) in builtin_templates().iter().enumerate() {
                tx.execute(
                    "INSERT INTO templates VALUES (?1, ?2, ?3, ?4, ?5, 1)",
                    params![id, name, insights, actions, i == 0],
                )?;
            }
            for id in MIGRATIONS {
                tx.execute("INSERT INTO grdb_migrations VALUES (?1)", [id])?;
            }
            tx.commit()?;
        }
        if applied > 0 {
            for (id, sql) in [
                (MIGRATIONS[1], include_str!("../migrations/v2.sql")),
                (MIGRATIONS[2], include_str!("../migrations/v3.sql")),
            ] {
                let exists: bool = db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier=?1)",
                    [id],
                    |r| r.get(0),
                )?;
                if !exists {
                    let tx = db.unchecked_transaction()?;
                    tx.execute_batch(sql)?;
                    if id == MIGRATIONS[1] {
                        for (i, (template, name, insights, actions)) in
                            builtin_templates().iter().enumerate()
                        {
                            tx.execute(
                                "INSERT INTO templates VALUES(?1,?2,?3,?4,?5,1)",
                                params![template, name, insights, actions, i == 0],
                            )?;
                        }
                    }
                    tx.execute("INSERT INTO grdb_migrations VALUES(?1)", [id])?;
                    tx.commit()?;
                }
            }
        }
        for (id, sql) in UPGRADES {
            let exists: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = ?1)",
                [id],
                |r| r.get(0),
            )?;
            if !exists {
                let tx = db.unchecked_transaction()?;
                tx.execute_batch(sql)?;
                tx.execute("INSERT INTO grdb_migrations VALUES (?1)", [id])?;
                tx.commit()?;
            }
        }
        // Flatten imported macOS merge chains so all callers resolve the same person.
        let parents = db
            .prepare("SELECT id,parent_id FROM speakers")?
            .query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
            })?
            .collect::<Result<std::collections::HashMap<_, _>, _>>()?;
        for (id, parent) in &parents {
            let mut root = parent.clone();
            let mut seen = std::collections::HashSet::from([id.clone()]);
            while let Some(p) = root.clone() {
                if !seen.insert(p.clone()) {
                    return Err(rusqlite::Error::InvalidQuery);
                }
                match parents.get(&p).cloned().flatten() {
                    Some(next) => root = Some(next),
                    None => break,
                }
            }
            if root != *parent {
                db.execute(
                    "UPDATE speakers SET parent_id=?2 WHERE id=?1",
                    params![id, root],
                )?;
            }
        }
        // Keep readable audio after a crash available for the transcription worker (as on macOS).
        let interrupted: Vec<String> = db
            .prepare("SELECT id FROM meetings WHERE status = 'recording'")?
            .query_map([], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        for id in interrupted {
            if !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
            {
                continue;
            }
            let folder = dir.join("recordings").join(&id);
            let duration = ["mic.wav", "system.wav"]
                .iter()
                .filter_map(|name| hound::WavReader::open(folder.join(name)).ok())
                .map(|reader| reader.duration() as f64 / reader.spec().sample_rate as f64)
                .fold(0.0, f64::max);
            let status = if duration > 0.0 {
                "recovered"
            } else {
                "error:interrupted"
            };
            db.execute(
                "UPDATE meetings SET status = ?2, duration = ?3 WHERE id = ?1",
                params![id, status, duration],
            )?;
        }
        // Don't retry a processing crash automatically: it may be the cause of the crash.
        db.execute(
            "UPDATE meetings SET status = 'error:interrupted' WHERE status LIKE 'processing%'",
            [],
        )?;
        // Recently Deleted keeps notes for 30 days.
        let expired: Vec<String> = db
            .prepare("SELECT id FROM meetings WHERE deleted_at < strftime('%Y-%m-%d %H:%M:%f', 'now', '-30 days')")?
            .query_map([], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        for id in expired {
            db.execute("DELETE FROM meetings WHERE id = ?1", [&id])?;
            if id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
            {
                let _ = std::fs::remove_dir_all(dir.join("recordings").join(&id));
            }
        }
        let store = Store {
            db,
            dir: dir.to_path_buf(),
        };
        if let Ok(config) = crate::settings::load(dir) {
            store.localize_templates(&config.language)?;
        }
        Ok(store)
    }

    pub fn localize_templates(&self, language: &str) -> rusqlite::Result<()> {
        let russian: serde_json::Value = serde_json::from_str(include_str!("../templates-ru.json"))
            .map_err(|_| rusqlite::Error::InvalidQuery)?;
        for (id, name, insights, actions) in builtin_templates() {
            let r = &russian[id];
            let local = language == "ru";
            self.db.execute("UPDATE templates SET name=CASE WHEN name IN (?2,?3) THEN ?4 ELSE name END,insights_prompt=CASE WHEN insights_prompt IN (?5,?6) THEN ?7 ELSE insights_prompt END,actions_prompt=CASE WHEN actions_prompt IN (?8,?9) THEN ?10 ELSE actions_prompt END WHERE id=?1 AND builtin=1",params![id,name,r["name"].as_str(),if local{r["name"].as_str().unwrap_or(name)}else{name},insights,r["insights"].as_str(),if local{r["insights"].as_str().unwrap_or(insights)}else{insights},actions,r["actions"].as_str(),if local{r["actions"].as_str().unwrap_or(&actions)}else{&actions}])?;
        }
        Ok(())
    }
    pub fn meeting_dir(&self, id: &str) -> PathBuf {
        self.dir.join("recordings").join(id)
    }

    pub fn new_meeting(&self, title: &str) -> rusqlite::Result<String> {
        let id = uuid::Uuid::new_v4().to_string().to_uppercase(); // Swift's UUID().uuidString
        self.db.execute(
            &format!("INSERT INTO meetings (id, title, created_at, duration, status, summary) VALUES (?1, ?2, {NOW}, 0, 'recording', '')"),
            params![id, title],
        )?;
        Ok(id)
    }

    pub fn set_status(&self, id: &str, status: &str) -> rusqlite::Result<()> {
        self.db.execute(
            "UPDATE meetings SET status = ?2 WHERE id = ?1",
            params![id, status],
        )?;
        Ok(())
    }

    pub fn set_duration(&self, id: &str, seconds: f64) -> rusqlite::Result<()> {
        self.db.execute(
            "UPDATE meetings SET duration = ?2 WHERE id = ?1",
            params![id, seconds],
        )?;
        Ok(())
    }

    pub fn meetings(&self) -> rusqlite::Result<Vec<Meeting>> {
        self.db
            .prepare("SELECT id, title, created_at, duration, status, summary, folder_id FROM meetings WHERE deleted_at IS NULL ORDER BY created_at DESC")?
            .query_map([], |r| {
                Ok(Meeting {
                    id: r.get(0)?,
                    title: r.get(1)?,
                    created_at: r.get(2)?,
                    duration: r.get(3)?,
                    status: r.get(4)?,
                    summary: r.get(5)?,
                    folder_id: r.get(6)?,
                })
            })?
            .collect()
    }
}

/// Port of Templates.swift (BuiltinTemplates.all): (id, name, insights, actions). Keep the text in sync.
fn builtin_templates() -> Vec<(&'static str, &'static str, &'static str, String)> {
    const STRICT: &str = "List only follow-ups a participant clearly committed to (\"I'll…\", \"we will…\", \"X will…\"). \
        Each item says who does what, and by when if a time was mentioned. \
        Skip suggestions, opinions, past work, and anything you are unsure about.";
    let typical = |t: &str| format!("{STRICT} Typical: {t}");
    vec![
        ("general", "General Meeting",
         "Give 3-6 key insights, 1-2 sentences each: decisions and why they were made, \
          disagreements, risks, open questions and important numbers. Skip greetings and small talk.",
         STRICT.to_string()),
        ("one-on-one", "1-on-1",
         "Give 2-5 insights about growth and wellbeing: feedback given or received, blockers, goals and progress, \
          frustrations, support the person needs. Skip routine status updates.",
         typical("manager removes a blocker, report finishes a development step, schedule a check-in.")),
        ("client", "Client Call",
         "Give 3-6 insights about the client: their situation and pain points, goals and success criteria, \
          stakeholders, budget and timeline constraints, objections, and what they already tried.",
         typical("send a proposal or documents, make introductions, get approvals, book the next call.")),
        ("sales", "Sales Call",
         "Give 3-6 insights: customer needs, decision process and budget, competitors considered, \
          objections and how they were handled, buying signals and concerns.",
         typical("send a quote, set up a trial, share references, loop in stakeholders.")),
        ("tech", "Technical Discussion",
         "Give 3-6 insights: architecture and design decisions with their trade-offs, chosen tools, \
          known risks and tech debt, unresolved technical questions, dependencies between teams.",
         typical("write a design doc, spike or prototype, fix a bug, review a PR.")),
        ("status", "Project Status / Standup",
         "Give 2-5 insights: progress against milestones, blockers and who can unblock them, \
          schedule or scope changes, risks to delivery.",
         STRICT.to_string()),
        ("interview", "Interview",
         "Give 3-6 insights about the candidate: relevant experience, demonstrated skills, \
          motivation, red flags, and what their questions reveal. Skip process logistics.",
         typical("schedule next round, check references, send a take-home task.")),
        ("workshop", "Brainstorm / Workshop",
         "Give 3-6 insights: strongest ideas and their rationale, where the group agreed, \
          points of debate, priorities chosen, questions that need research.",
         STRICT.to_string()),
        ("lecture", "Lecture / Learning",
         "Give 4-8 insights: the main concepts explained, definitions, examples worth remembering, \
          and references or resources mentioned.",
         "List homework, readings or exercises that were assigned, if any.".to_string()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_future_library_without_deleting_its_data() {
        let dir = std::env::temp_dir().join(format!("future-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let store = Store::open(&dir).unwrap();
        let id = store.new_meeting("Keep this").unwrap();
        store
            .db
            .execute("INSERT INTO grdb_migrations VALUES('v999_future')", [])
            .unwrap();
        drop(store);
        assert!(Store::open(&dir).is_err());
        let db = Connection::open(dir.join("meetnotes.sqlite")).unwrap();
        assert_eq!(
            db.query_row("SELECT title FROM meetings WHERE id=?1", [id], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "Keep this"
        );
        drop(db);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn template_localization_preserves_user_changes() {
        let dir = std::env::temp_dir().join(format!("locale-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let store = Store::open(&dir).unwrap();
        store.localize_templates("ru").unwrap();
        let ru: String = store
            .db
            .query_row("SELECT name FROM templates WHERE id='general'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_ne!(ru, "General Meeting");
        store
            .db
            .execute(
                "UPDATE templates SET insights_prompt='My custom instructions' WHERE id='general'",
                [],
            )
            .unwrap();
        store.localize_templates("en").unwrap();
        assert_eq!(
            store
                .db
                .query_row(
                    "SELECT insights_prompt FROM templates WHERE id='general'",
                    [],
                    |r| r.get::<_, String>(0)
                )
                .unwrap(),
            "My custom instructions"
        );
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn upgrades_v1_json_tasks_and_tags_without_losing_notes() {
        let dir = std::env::temp_dir().join(format!("v1-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let db = Connection::open(dir.join("meetnotes.sqlite")).unwrap();
        db.execute_batch("CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY);INSERT INTO grdb_migrations VALUES('v1');CREATE TABLE meetings(id TEXT PRIMARY KEY,title TEXT,created_at TEXT,duration REAL DEFAULT 0,status TEXT,summary TEXT DEFAULT '',action_items TEXT DEFAULT '[]',tags TEXT DEFAULT '[]');CREATE TABLE speakers(id TEXT PRIMARY KEY,name TEXT,embedding TEXT,embedding_model TEXT,created_at TEXT);CREATE TABLE segments(id INTEGER PRIMARY KEY,meeting_id TEXT,speaker_id TEXT,source TEXT,start REAL,end REAL,text TEXT,original_text TEXT,irrelevant BOOLEAN DEFAULT 0);INSERT INTO meetings(id,title,created_at,status,action_items,tags) VALUES('old','From Mac','2026-10-20','done','[\"Send notes\"]','[\"project\"]');").unwrap();
        drop(db);
        let store = Store::open(&dir).unwrap();
        assert_eq!(
            store
                .db
                .query_row("SELECT text FROM action_items", [], |r| r
                    .get::<_, String>(0))
                .unwrap(),
            "Send notes"
        );
        assert_eq!(
            store
                .db
                .query_row("SELECT name FROM tags", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "project"
        );
        assert_eq!(
            store
                .db
                .query_row("SELECT count(*) FROM grdb_migrations", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            5
        );
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn fresh_library_matches_macos_layout() {
        let dir = std::env::temp_dir().join(format!("meetnotes-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let s = Store::open(&dir).unwrap();
        let id = s.new_meeting("Standup").unwrap();
        assert_eq!(s.meetings().unwrap()[0].id, id);
        let created: String =
            s.db.query_row("SELECT created_at FROM meetings", [], |r| r.get(0))
                .unwrap();
        assert_eq!(created.len(), "2026-10-20 21:17:57.327".len());
        // FTS triggers from schema.sql keep the search index in sync.
        let hits: i64 =
            s.db.query_row(
                "SELECT count(*) FROM meetings_fts WHERE meetings_fts MATCH 'standup'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(hits, 1);
        let templates: i64 =
            s.db.query_row("SELECT count(*) FROM templates WHERE builtin", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(templates, 9);
        // Reopening applies nothing twice and marks the unfinished recording.
        drop(s);
        let s = Store::open(&dir).unwrap();
        assert_eq!(s.meetings().unwrap()[0].status, "error:interrupted");
        drop(s);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn upgrades_v3_library_without_losing_data() {
        let dir = std::env::temp_dir().join(format!("meetnotes-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = Connection::open(dir.join("meetnotes.sqlite")).unwrap();
        db.execute_batch(include_str!("../schema.sql")).unwrap();
        db.execute_batch("CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations VALUES ('v1'), ('v2_folders_tags'), ('v3_attachments_live_queries');
            INSERT INTO meetings (id, title, created_at, status) VALUES ('existing', 'From Mac', '2026-10-21 10:00:00.000', 'done');
            INSERT INTO speakers (id, name, embedding, embedding_model, created_at) VALUES ('voice', 'Alice', '[0.1]', 'wespeaker_v2', '2026-10-21 10:00:00.000');
            INSERT INTO segments (meeting_id, speaker_id, source, start, end, text) VALUES ('existing', 'voice', 'system', 0, 2, 'Existing transcript');
            INSERT INTO action_items (meeting_id, text, created_at) VALUES ('existing', 'Follow up', '2026-10-21 10:00:00.000');").unwrap();
        drop(db);
        let s = Store::open(&dir).unwrap();
        assert_eq!(s.meetings().unwrap()[0].title, "From Mac");
        let samples: String =
            s.db.query_row("SELECT voice_samples FROM speakers", [], |r| r.get(0))
                .unwrap();
        assert_eq!(samples, "[]");
        let overlap: bool =
            s.db.query_row("SELECT overlap FROM segments", [], |r| r.get(0))
                .unwrap();
        assert!(!overlap);
        s.db.execute_batch(
            "UPDATE action_items SET task_ref = 'https://example.test/task/1';
            UPDATE meetings SET max_speakers = 3, expected_speakers = 2;
            UPDATE speakers SET voice_samples = '[[0.1]]'; UPDATE segments SET overlap = 1;",
        )
        .unwrap();
        drop(s);
        // Already-upgraded macOS libraries must also reopen without reapplying ALTER TABLE.
        let s = Store::open(&dir).unwrap();
        let versions: i64 =
            s.db.query_row("SELECT count(*) FROM grdb_migrations", [], |r| r.get(0))
                .unwrap();
        assert_eq!(versions, 5);
        let task: String =
            s.db.query_row("SELECT task_ref FROM action_items", [], |r| r.get(0))
                .unwrap();
        assert_eq!(task, "https://example.test/task/1");
        let hits: i64 =
            s.db.query_row(
                "SELECT count(*) FROM segments_fts WHERE segments_fts MATCH 'transcript'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(hits, 1);
        drop(s);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn recovers_checkpointed_recording_after_restart() {
        let dir = std::env::temp_dir().join(format!("meetnotes-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let s = Store::open(&dir).unwrap();
        let id = s.new_meeting("Interrupted call").unwrap();
        std::fs::create_dir_all(s.meeting_dir(&id)).unwrap();
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer =
            hound::WavWriter::create(s.meeting_dir(&id).join("mic.wav"), spec).unwrap();
        for _ in 0..16000 {
            writer.write_sample(123i16).unwrap();
        }
        writer.flush().unwrap();
        drop(s);
        let s = Store::open(&dir).unwrap();
        let meeting = &s.meetings().unwrap()[0];
        assert_eq!(meeting.status, "recovered");
        assert_eq!(meeting.duration, 1.0);
        writer.finalize().unwrap();
        drop(s);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
