use crate::store::Store;
use rusqlite::{params, types::ValueRef, ToSql};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
type Res<T> = Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
pub fn query(db: &rusqlite::Connection, sql: &str, args: &[&dyn ToSql]) -> Res<Vec<Value>> {
    let mut statement = db.prepare(sql).map_err(err)?;
    let names: Vec<String> = statement
        .column_names()
        .iter()
        .map(|x| x.to_string())
        .collect();
    let rows = statement
        .query_map(args, |row| {
            let mut out = serde_json::Map::new();
            for (i, name) in names.iter().enumerate() {
                let value = match row.get_ref(i)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(s) => json!(String::from_utf8_lossy(s)),
                    ValueRef::Blob(_) => Value::Null,
                };
                out.insert(name.clone(), value);
            }
            Ok(Value::Object(out))
        })
        .map_err(err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(err)
}
pub fn meeting_path(store: &Store, id: &str) -> Res<PathBuf> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err("Invalid meeting identifier".into());
    }
    Ok(store.meeting_dir(id))
}
pub fn view(store: &Store, kind: &str, id: Option<&str>, search: &str) -> Res<Value> {
    let db = &store.db;
    Ok(match kind {
        "document"=>{let id=id.ok_or("Select a meeting")?;json!({
            "meeting":query(db,"SELECT * FROM meetings WHERE id=?1",&[&id])?.first().ok_or("Meeting not found")?,
            "segments":query(db,"SELECT s.*,COALESCE(v.parent_id,v.id) AS person_id,COALESCE(p.name,v.name,'Speaker') AS speaker_name FROM segments s LEFT JOIN speakers v ON v.id=s.speaker_id LEFT JOIN speakers p ON p.id=v.parent_id WHERE meeting_id=?1 ORDER BY start,id",&[&id])?,
            "actions":query(db,"SELECT * FROM action_items WHERE meeting_id=?1 ORDER BY id",&[&id])?,
            "insights":query(db,"SELECT * FROM insights WHERE meeting_id=?1 ORDER BY sort_order",&[&id])?,
            "tags":query(db,"SELECT t.* FROM tags t JOIN meeting_tags mt ON mt.tag_id=t.id WHERE mt.meeting_id=?1 ORDER BY name",&[&id])?,
            "bookmarks":query(db,"SELECT * FROM bookmarks WHERE meeting_id=?1 ORDER BY time",&[&id])?,
            "attachments":query(db,"SELECT * FROM attachments WHERE meeting_id=?1 ORDER BY id",&[&id])?
        })},
        "folders"=>json!(query(db,"SELECT f.*,(SELECT count(*) FROM meetings m WHERE m.folder_id=f.id AND m.deleted_at IS NULL) AS count FROM folders f ORDER BY sort_order,name",&[])?),
        "people"=>json!(query(db,"SELECT s.*,(SELECT count(DISTINCT g.meeting_id) FROM segments g JOIN meetings m ON m.id=g.meeting_id LEFT JOIN speakers voice ON voice.id=g.speaker_id WHERE (g.speaker_id=s.id OR voice.parent_id=s.id) AND m.deleted_at IS NULL) AS count FROM speakers s WHERE parent_id IS NULL ORDER BY name",&[])?),
        "tags"=>json!(query(db,"SELECT t.*,(SELECT count(*) FROM meeting_tags mt JOIN meetings m ON m.id=mt.meeting_id WHERE mt.tag_id=t.id AND m.deleted_at IS NULL) AS count FROM tags t ORDER BY name",&[])?),
        "actions"=>json!(query(db,"SELECT a.*,m.title AS meeting_title FROM action_items a JOIN meetings m ON m.id=a.meeting_id WHERE m.deleted_at IS NULL ORDER BY completed,due_date IS NULL,due_date,a.id DESC",&[])?),
        "trash"=>json!(query(db,"SELECT * FROM meetings WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC",&[])?),
        "templates"=>json!(query(db,"SELECT * FROM templates ORDER BY is_default DESC,name",&[])?),
        "chats"=>json!(query(db,"SELECT * FROM chat_sessions WHERE (?1 IS NULL AND meeting_id IS NULL) OR meeting_id=?1 ORDER BY updated_at DESC",&[&id])?),
        "messages"=>json!(query(db,"SELECT * FROM chat_messages WHERE session_id=?1 ORDER BY id",&[&id])?),
        "queries"=>json!(query(db,"SELECT * FROM saved_queries ORDER BY name",&[])?),
        "search"=>json!(search_library(store,search,id)?),
        "related"=>{let id=id.ok_or("Select a meeting")?;json!(query(db,"SELECT m.*,count(mt.tag_id) AS shared_tags FROM meetings m JOIN meeting_tags mt ON mt.meeting_id=m.id WHERE m.id<>?1 AND m.deleted_at IS NULL AND mt.tag_id IN (SELECT tag_id FROM meeting_tags WHERE meeting_id=?1) GROUP BY m.id ORDER BY shared_tags DESC LIMIT 8",&[&id])?)},
        _=>return Err("Unknown view".into())
    })
}
pub fn search_library(store: &Store, text: &str, meeting: Option<&str>) -> Res<Vec<Value>> {
    search_scoped(store, text, meeting, &serde_json::json!({}))
}
pub fn scope_filter(alias: &str) -> String {
    format!("m.deleted_at IS NULL AND (?2 IS NULL OR m.id=?2) AND (COALESCE(json_array_length(json_extract(?3,'$.meetings')),0)=0 OR m.id IN (SELECT value FROM json_each(?3,'$.meetings'))) AND (COALESCE(json_extract(?3,'$.folder'),'')='' OR m.folder_id=json_extract(?3,'$.folder')) AND (COALESCE(json_extract(?3,'$.tag'),'')='' OR EXISTS(SELECT 1 FROM meeting_tags mt WHERE mt.meeting_id=m.id AND mt.tag_id=json_extract(?3,'$.tag'))) AND (COALESCE(json_extract(?3,'$.person'),'')='' OR EXISTS(SELECT 1 FROM segments g LEFT JOIN speakers p ON p.id=g.speaker_id WHERE g.meeting_id=m.id AND (g.speaker_id=json_extract(?3,'$.person') OR p.parent_id=json_extract(?3,'$.person')) AND g.start<={alias}.end AND g.end>={alias}.start)) AND (COALESCE(json_extract(?3,'$.from'),'')='' OR date(m.created_at)>=json_extract(?3,'$.from')) AND (COALESCE(json_extract(?3,'$.to'),'')='' OR date(m.created_at)<=json_extract(?3,'$.to')) AND (json_extract(?3,'$.start') IS NULL OR {alias}.end>=json_extract(?3,'$.start')) AND (json_extract(?3,'$.end') IS NULL OR {alias}.start<=json_extract(?3,'$.end'))")
}
pub fn search_scoped(
    store: &Store,
    text: &str,
    meeting: Option<&str>,
    scope: &Value,
) -> Res<Vec<Value>> {
    let tokens = text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(|s| format!("\"{s}\""))
        .collect::<Vec<_>>();
    let json = scope.to_string();
    let filter = scope_filter("s");
    let columns = "s.*,m.title,COALESCE(root.name,p.name,'Speaker') AS speaker_name";
    let joins="JOIN meetings m ON m.id=s.meeting_id LEFT JOIN speakers p ON p.id=s.speaker_id LEFT JOIN speakers root ON root.id=p.parent_id";
    if tokens.is_empty() {
        return query(&store.db,&format!("SELECT {columns} FROM segments s {joins} WHERE {filter} AND ?1='' ORDER BY m.created_at DESC,s.start LIMIT 60"),&[&"",&meeting,&json]);
    }
    query(&store.db,&format!("SELECT {columns},bm25(segments_fts) AS score FROM segments_fts JOIN segments s ON s.id=segments_fts.rowid {joins} WHERE segments_fts MATCH ?1 AND {filter} ORDER BY score LIMIT 60"),&[&tokens.join(" OR "),&meeting,&json])
}
fn strval<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub fn mutate(store: &mut Store, op: &str, id: &str, v: &Value) -> Res<Value> {
    let db = &store.db;
    let now = "strftime('%Y-%m-%d %H:%M:%f','now')";
    match op {
        "meeting" => {
            for key in ["expected_speakers", "max_speakers"] {
                if let Some(value) = v.get(key).filter(|v| !v.is_null()) {
                    if !value.as_i64().is_some_and(|n| (1..=100).contains(&n)) {
                        return Err("Speaker count must be between 1 and 100".into());
                    }
                }
            }
            db.execute(&format!("UPDATE meetings SET title=COALESCE(?2,title),notes=COALESCE(?3,notes),folder_id=CASE WHEN ?4 THEN ?5 ELSE folder_id END,template_id=CASE WHEN ?6 THEN ?7 ELSE template_id END,modified_at={now},expected_speakers=CASE WHEN ?8 THEN ?9 ELSE expected_speakers END,max_speakers=CASE WHEN ?10 THEN ?11 ELSE max_speakers END WHERE id=?1"),params![id,v["title"].as_str(),v["notes"].as_str(),v.get("folder_id").is_some(),v["folder_id"].as_str(),v.get("template_id").is_some(),v["template_id"].as_str(),v.get("expected_speakers").is_some(),v["expected_speakers"].as_i64(),v.get("max_speakers").is_some(),v["max_speakers"].as_i64()]).map_err(err)?;
        }
        "trash" => {
            if db.execute(&format!("UPDATE meetings SET deleted_at={now} WHERE id=?1 AND status NOT LIKE 'processing%' AND status NOT LIKE 'queued%' AND status NOT IN ('recording','recovered')"),[id]).map_err(err)? == 0 { return Err("Finish or cancel processing before deleting this meeting".into()); }
        }
        "restore" => {
            db.execute("UPDATE meetings SET deleted_at=NULL WHERE id=?1", [id])
                .map_err(err)?;
        }
        "delete" => {
            let path = meeting_path(store, id)?;
            let changed = db
                .execute(
                    "DELETE FROM meetings WHERE id=?1 AND deleted_at IS NOT NULL",
                    [id],
                )
                .map_err(err)?;
            if changed > 0 && path.exists() {
                std::fs::remove_dir_all(path).map_err(err)?;
            }
        }
        "segment" => {
            db.execute("UPDATE segments SET original_text=COALESCE(original_text,text),text=?2,speaker_id=?3,user_edited=1 WHERE id=?1",params![id,strval(v,"text"),v["speaker_id"].as_str()]).map_err(err)?;
        }
        "segment.restore" => {
            db.execute("UPDATE segments SET text=COALESCE(original_text,text),original_text=NULL,irrelevant=0,user_edited=0 WHERE id=?1",[id]).map_err(err)?;
        }
        "action" => {
            if id.is_empty() {
                db.execute(&format!("INSERT INTO action_items (meeting_id,text,assignee,due_date,created_at) VALUES (?1,?2,?3,?4,{now})"),params![strval(v,"meeting_id"),strval(v,"text"),v["assignee"].as_str(),v["due_date"].as_str()]).map_err(err)?;
            } else {
                db.execute("UPDATE action_items SET completed=COALESCE(?2,completed),text=COALESCE(?3,text),assignee=COALESCE(?4,assignee),due_date=COALESCE(?5,due_date) WHERE id=?1",params![id,v["completed"].as_bool(),v["text"].as_str(),v["assignee"].as_str(),v["due_date"].as_str()]).map_err(err)?;
            }
        }
        "action.delete" => {
            db.execute("DELETE FROM action_items WHERE id=?1", [id])
                .map_err(err)?;
        }
        "action.link" => {
            db.execute(
                "UPDATE action_items SET task_ref=?2 WHERE id=?1",
                params![id, strval(v, "url")],
            )
            .map_err(err)?;
        }
        "speaker" => {
            let sid = if id.is_empty() {
                uuid::Uuid::new_v4().to_string()
            } else {
                id.to_string()
            };
            db.execute(&format!("INSERT INTO speakers (id,name,embedding,embedding_model,created_at,email,company,position,notes) VALUES (?1,?2,'[]','',{now},?3,?4,?5,?6) ON CONFLICT(id) DO UPDATE SET name=excluded.name,email=excluded.email,company=excluded.company,position=excluded.position,notes=excluded.notes"),params![sid,strval(v,"name"),strval(v,"email"),strval(v,"company"),strval(v,"position"),strval(v,"notes")]).map_err(err)?;
        }
        "speaker.merge" => {
            let target = strval(v, "target");
            if target == id || id == "me" || target == "me" {
                return Err("Choose two different people".into());
            }
            let mut current = Some(target.to_string());
            let mut seen = std::collections::HashSet::new();
            while let Some(person) = current {
                if person == id || !seen.insert(person.clone()) {
                    return Err("Merging would create a cycle".into());
                }
                current = db
                    .query_row(
                        "SELECT parent_id FROM speakers WHERE id=?1",
                        [person],
                        |r| r.get(0),
                    )
                    .map_err(err)?;
            }
            db.execute(
                "UPDATE speakers SET parent_id=?2 WHERE id=?1 OR parent_id=?1",
                params![id, target],
            )
            .map_err(err)?;
        }
        "speaker.assign" => {
            db.execute("UPDATE segments SET speaker_id=?2 WHERE meeting_id=?1 AND speaker_id IS ?3 AND (?4 IS NULL OR source=?4)",params![id,v["target"].as_str(),v["from"].as_str(),v["source"].as_str()]).map_err(err)?;
        }
        "folder" => {
            let fid = if id.is_empty() {
                uuid::Uuid::new_v4().to_string()
            } else {
                id.to_string()
            };
            let parent = v["parent_id"].as_str();
            let mut current = parent.map(str::to_string);
            let mut seen = std::collections::HashSet::new();
            while let Some(p) = current {
                if p == fid || !seen.insert(p.clone()) {
                    return Err("Folder cycle".into());
                }
                current = db
                    .query_row("SELECT parent_id FROM folders WHERE id=?1", [p], |r| {
                        r.get(0)
                    })
                    .map_err(err)?;
            }
            db.execute(&format!("INSERT INTO folders (id,name,parent_id,context,created_at,icon,color,template_id) VALUES (?1,?2,?3,?4,{now},?5,?6,?7) ON CONFLICT(id) DO UPDATE SET name=excluded.name,parent_id=excluded.parent_id,context=excluded.context,icon=excluded.icon,color=excluded.color,template_id=excluded.template_id"),params![fid,strval(v,"name"),parent,strval(v,"context"),v["icon"].as_str().unwrap_or("folder"),v["color"].as_str().unwrap_or("blue"),v["template_id"].as_str()]).map_err(err)?;
        }
        "folder.delete" => {
            db.execute("DELETE FROM folders WHERE id=?1", [id])
                .map_err(err)?;
        }
        "tags" => {
            let tx = store.db.unchecked_transaction().map_err(err)?;
            tx.execute("DELETE FROM meeting_tags WHERE meeting_id=?1", [id])
                .map_err(err)?;
            for name in strval(v, "names")
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                let tid = uuid::Uuid::new_v4().to_string();
                tx.execute(
                    "INSERT OR IGNORE INTO tags(id,name) VALUES(?1,?2)",
                    params![tid, name],
                )
                .map_err(err)?;
                tx.execute("INSERT OR IGNORE INTO meeting_tags SELECT ?1,id FROM tags WHERE name=?2 COLLATE NOCASE",params![id,name]).map_err(err)?;
            }
            tx.commit().map_err(err)?;
        }
        "tag"=>{db.execute("UPDATE tags SET name=?2 WHERE id=?1",params![id,strval(v,"name")]).map_err(err)?;}
        "tag.delete" => {
            db.execute("DELETE FROM tags WHERE id=?1", [id])
                .map_err(err)?;
        }
        "bookmark" => {
            let time = v["time"]
                .as_f64()
                .filter(|t| t.is_finite() && *t >= 0.0)
                .ok_or("Invalid timestamp")?;
            db.execute(
                "INSERT INTO bookmarks(meeting_id,time,label) VALUES(?1,?2,?3)",
                params![id, time, strval(v, "label")],
            )
            .map_err(err)?;
        }
        "bookmark.delete" => {
            db.execute("DELETE FROM bookmarks WHERE id=?1", [id])
                .map_err(err)?;
        }
        "template" => {
            let tid = if id.is_empty() {
                uuid::Uuid::new_v4().to_string()
            } else {
                id.to_string()
            };
            db.execute("INSERT INTO templates(id,name,insights_prompt,actions_prompt) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET name=excluded.name,insights_prompt=excluded.insights_prompt,actions_prompt=excluded.actions_prompt",params![tid,strval(v,"name"),strval(v,"insights_prompt"),strval(v,"actions_prompt")]).map_err(err)?;
        }
        "template.default" => {
            let tx = store.db.unchecked_transaction().map_err(err)?;
            tx.execute("UPDATE templates SET is_default=(id=?1)", [id])
                .map_err(err)?;
            tx.commit().map_err(err)?;
        }
        "query.delete" => {
            db.execute("DELETE FROM saved_queries WHERE id=?1", [id])
                .map_err(err)?;
        }
        "query" => {
            let qid = if id.is_empty() {
                uuid::Uuid::new_v4().to_string()
            } else {
                id.to_string()
            };
            let schedule = strval(v, "schedule");
            if !["manual", "daily", "weekly"].contains(&schedule) {
                return Err("Invalid schedule".into());
            }
            let hour=v["hour"].as_u64().unwrap_or(9).min(23)as u32;let weekday=v["weekday"].as_u64().unwrap_or(2).clamp(1,7)as u32;
            let kind=v["scope_kind"].as_str().unwrap_or("all");if !["all","person","folder","tag"].contains(&kind){return Err("Invalid query scope".into());}
            let next = crate::schedule::next(schedule, hour, weekday);
            db.execute(&format!("INSERT INTO saved_queries(id,name,prompt,scope_kind,period_days,schedule,hour,weekday,created_at,next_run_at,scope_id) VALUES(?1,?2,?3,?7,?4,?5,?8,?9,{now},?6,?10) ON CONFLICT(id) DO UPDATE SET name=excluded.name,prompt=excluded.prompt,period_days=excluded.period_days,schedule=excluded.schedule,next_run_at=excluded.next_run_at,scope_kind=excluded.scope_kind,scope_id=excluded.scope_id,hour=excluded.hour,weekday=excluded.weekday"),params![qid,strval(v,"name"),strval(v,"prompt"),v["period_days"].as_i64().unwrap_or(7).clamp(1,3650),schedule,next,kind,hour,weekday,v["scope_id"].as_str()]).map_err(err)?;
        }
        _ => return Err("Unknown operation".into()),
    }
    Ok(json!(true))
}
pub fn attachment_path(store: &Store, id: &str, name: &str) -> Res<PathBuf> {
    if name.is_empty()
        || Path::new(name).components().count() != 1
        || name == ".."
        || name.contains(['/', '\\', ':'])
    {
        return Err("Invalid attachment filename".into());
    }
    Ok(meeting_path(store, id)?.join("attachments").join(name))
}
pub fn attach(store: &Store, id: &str, path: &Path, time: Option<f64>) -> Res<()> {
    let dir = meeting_path(store, id)?.join("attachments");
    std::fs::create_dir_all(&dir).map_err(err)?;
    let original = path
        .file_name()
        .ok_or("Invalid filename")?
        .to_string_lossy();
    let filename = format!("{}-{}", uuid::Uuid::new_v4(), original);
    let dest = dir.join(&filename);
    std::fs::copy(path, &dest).map_err(err)?;
    let size = std::fs::metadata(&dest).map_err(err)?.len();
    let image = ["png", "jpg", "jpeg", "gif", "webp"].contains(
        &path
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .to_lowercase()
            .as_str(),
    );
    store.db.execute("INSERT INTO attachments(meeting_id,file_name,file_size,is_image,recording_time,created_at) VALUES(?1,?2,?3,?4,?5,strftime('%Y-%m-%d %H:%M:%f','now'))",params![id,filename,size,image,time]).map_err(err)?;
    Ok(())
}
pub fn markdown(store: &Store, id: &str) -> Res<String> {
    let d = view(store, "document", Some(id), "")?;
    let m = &d["meeting"];
    let mut text = format!(
        "---\ntitle: {}\ndate: {}\n---\n\n# {}\n\n{}\n\n",
        serde_json::to_string(&m["title"]).map_err(err)?,
        m["created_at"],
        strval(m, "title"),
        strval(m, "summary")
    );
    text.push_str("## Key insights\n\n");
    for i in d["insights"].as_array().unwrap() {
        text.push_str(&format!("- {}\n", strval(i, "text")));
    }
    text.push_str("\n## Action items\n\n");
    for a in d["actions"].as_array().unwrap() {
        text.push_str(&format!(
            "- [{}] {} {} {}\n",
            if a["completed"] == 1 { "x" } else { " " },
            strval(a, "text"),
            strval(a, "assignee"),
            strval(a, "due_date")
        ));
    }
    text.push_str(&format!(
        "\n## Notes\n\n{}\n\n## Transcript\n\n",
        strval(m, "notes")
    ));
    for s in d["segments"].as_array().unwrap() {
        text.push_str(&format!(
            "[{}] **{}:** {}\n\n",
            timestamp(s["start"].as_f64().unwrap_or(0.0)),
            strval(s, "speaker_name"),
            strval(s, "text")
        ));
    }
    text.push_str("\n## Attachments\n\n");
    for a in d["attachments"].as_array().unwrap() {
        let name = strval(a, "file_name");
        let encoded = name
            .as_bytes()
            .iter()
            .map(|b| {
                if b.is_ascii_alphanumeric() || b"._-".contains(b) {
                    (*b as char).to_string()
                } else {
                    format!("%{b:02X}")
                }
            })
            .collect::<String>();
        text.push_str(&format!(
            "- [{}]({id}.attachments/{encoded})\n",
            name.replace(['[', ']'], "")
        ));
    }
    Ok(text)
}
pub fn export_to(store: &Store, id: &str, path: &Path) -> Res<()> {
    let text = markdown(store, id)?;
    let parent = path.parent().ok_or("Invalid export path")?;
    std::fs::create_dir_all(parent).map_err(err)?;
    let attachments = view(store, "document", Some(id), "")?;
    for a in attachments["attachments"].as_array().unwrap() {
        let name = strval(a, "file_name");
        if Path::new(name).components().count() != 1 || name == ".." {
            return Err("Invalid attachment filename".into());
        }
        let source = meeting_path(store, id)?.join("attachments").join(name);
        let destination = parent.join(format!("{id}.attachments"));
        std::fs::create_dir_all(&destination).map_err(err)?;
        std::fs::copy(source, destination.join(name)).map_err(err)?;
    }
    let temporary = path.with_extension("md.part");
    std::fs::write(&temporary, text).map_err(err)?;
    std::fs::rename(temporary, path).map_err(err)
}
pub fn timestamp(t: f64) -> String {
    format!("{}:{:02}", t.max(0.0) as u64 / 60, t.max(0.0) as u64 % 60)
}

#[cfg(test)]
mod tests {
    #[test]
    fn patches_keep_metadata_and_filters_apply_before_ranking() {
        let dir = std::env::temp_dir().join(format!("domain-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let mut s = crate::store::Store::open(&dir).unwrap();
        let a = s.new_meeting("first").unwrap();
        let b = s.new_meeting("second").unwrap();
        super::mutate(
            &mut s,
            "folder",
            "folder",
            &serde_json::json!({"name":"Project"}),
        )
        .unwrap();
        super::mutate(
            &mut s,
            "meeting",
            &a,
            &serde_json::json!({"folder_id":"folder","expected_speakers":2,"max_speakers":10}),
        )
        .unwrap();
        super::mutate(
            &mut s,
            "meeting",
            &a,
            &serde_json::json!({"notes":"Keep notes"}),
        )
        .unwrap();
        let row = super::view(&s, "document", Some(&a), "").unwrap();
        assert_eq!(row["meeting"]["folder_id"], "folder");
        assert_eq!(row["meeting"]["expected_speakers"], 2);
        assert_eq!(row["meeting"]["max_speakers"], 10);
        for invalid in [
            serde_json::json!(0),
            serde_json::json!(-1),
            serde_json::json!(101),
            serde_json::json!(2.5),
            serde_json::json!("10"),
        ] {
            assert!(super::mutate(
                &mut s,
                "meeting",
                &a,
                &serde_json::json!({"expected_speakers":invalid})
            )
            .is_err());
            assert!(super::mutate(
                &mut s,
                "meeting",
                &a,
                &serde_json::json!({"max_speakers":invalid})
            )
            .is_err());
        }
        for id in [&a, &b] {
            s.db.execute("INSERT INTO segments(meeting_id,source,start,end,text) VALUES(?1,'system',10,20,'project launch')",[id]).unwrap();
            s.set_status(id, "done").unwrap();
        }
        assert_eq!(
            super::search_scoped(
                &s,
                "project",
                None,
                &serde_json::json!({"meetings":[a],"start":12,"end":18})
            )
            .unwrap()
            .len(),
            1
        );
        assert!(
            super::search_scoped(&s, "project", None, &serde_json::json!({"start":30}))
                .unwrap()
                .is_empty()
        );
        s.db.execute("INSERT INTO action_items(meeting_id,text,completed,created_at) VALUES(?1,'task',1,'now')",[&a]).unwrap();
        super::mutate(&mut s, "action", "1", &serde_json::json!({"text":"edited"})).unwrap();
        assert_eq!(
            s.db.query_row("SELECT completed FROM action_items WHERE id=1", [], |r| r
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            1
        );
        s.set_status(&a, "queued:index").unwrap();
        assert!(super::mutate(&mut s, "trash", &a, &serde_json::json!({})).is_err());
        drop(s);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rejects_path_escape() {
        let dir = std::env::temp_dir().join(format!("domain-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let s = crate::store::Store::open(&dir).unwrap();
        assert!(super::meeting_path(&s, "../outside").is_err());
        assert!(super::meeting_path(&s, "abc-123").is_ok());
        drop(s);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
