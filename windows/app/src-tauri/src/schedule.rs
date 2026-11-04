use crate::{domain, AppState};
use chrono::{Datelike, TimeZone};
use std::{sync::atomic::Ordering, time::Duration};
use tauri::{AppHandle, Manager};
pub fn next(schedule: &str, hour: u32, weekday: u32) -> Option<String> {
    next_after(chrono::Local::now(), schedule, hour, weekday)
}
fn next_after(
    now: chrono::DateTime<chrono::Local>,
    schedule: &str,
    hour: u32,
    weekday: u32,
) -> Option<String> {
    if !["daily", "weekly"].contains(&schedule) {
        return None;
    }
    for offset in 0..9 {
        let date = now.date_naive() + chrono::Duration::days(offset);
        if schedule == "weekly" && date.weekday().number_from_sunday() != weekday.clamp(1, 7) {
            continue;
        }
        if let Some(time) = chrono::Local
            .with_ymd_and_hms(date.year(), date.month(), date.day(), hour.min(23), 0, 0)
            .earliest()
        {
            if time > now {
                return Some(
                    time.with_timezone(&chrono::Utc)
                        .format("%Y-%m-%d %H:%M:%S%.3f")
                        .to_string(),
                );
            }
        }
    }
    None
}
pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        while !app.state::<AppState>().shutdown.load(Ordering::Relaxed) {
            let due = {
                let state = app.state::<AppState>();
                let store = state.store.lock().unwrap();
                domain::query(&store.db,"SELECT id,schedule,hour,weekday FROM saved_queries WHERE schedule IN ('daily','weekly') AND next_run_at<=strftime('%Y-%m-%d %H:%M:%f','now') ORDER BY next_run_at LIMIT 1",&[]).ok().and_then(|mut rows|rows.pop())
            };
            if let Some(query) = due {
                if let Some(id) = query["id"].as_str() {
                    let next = next(
                        query["schedule"].as_str().unwrap_or("manual"),
                        query["hour"].as_u64().unwrap_or(9) as u32,
                        query["weekday"].as_u64().unwrap_or(2) as u32,
                    );
                    let _ = app.state::<AppState>().store.lock().unwrap().db.execute(
                        "UPDATE saved_queries SET next_run_at=?2,last_status='running' WHERE id=?1",
                        rusqlite::params![id, next],
                    );
                    let result = tauri::async_runtime::block_on(crate::commands::run_query(
                        app.clone(),
                        id.into(),
                    ));
                    if let Err(e) = result {
                        let _ = app.state::<AppState>().store.lock().unwrap().db.execute(
                            "UPDATE saved_queries SET last_status=?2 WHERE id=?1",
                            rusqlite::params![id, format!("error:{e}")],
                        );
                    }
                }
            }
            std::thread::sleep(Duration::from_secs(5));
        }
    });
}
#[cfg(test)]
mod tests {
    #[test]
    fn schedules_in_future_and_manual_does_not_run() {
        let now = chrono::Local::now();
        let next = super::next_after(now, "daily", 9, 2).unwrap();
        let parsed = chrono::NaiveDateTime::parse_from_str(&next, "%Y-%m-%d %H:%M:%S%.f")
            .unwrap()
            .and_utc();
        assert!(parsed > now.with_timezone(&chrono::Utc));
        assert!(parsed < now.with_timezone(&chrono::Utc) + chrono::Duration::hours(26));
        assert!(super::next("manual", 9, 2).is_none());
    }
}
