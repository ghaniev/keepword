use crate::{domain, AppState};
use base64::Engine;
use screenshots::{
    image::{self, RgbaImage},
    Screen,
};
use serde_json::{json, Value};
use std::{
    io::Cursor,
    sync::{Mutex, OnceLock},
};
use tauri::{AppHandle, Emitter, Manager};
type Res<T> = Result<T, String>;
struct Pending {
    token: String,
    id: String,
    image: RgbaImage,
    time: Option<f64>,
}
static PENDING: OnceLock<Mutex<Option<Pending>>> = OnceLock::new();
#[tauri::command]
pub fn capture_displays() -> Res<Vec<Value>> {
    Ok(Screen::all().map_err(|e|e.to_string())?.iter().map(|s|json!({"id":s.display_info.id,"width":s.display_info.width,"height":s.display_info.height,"primary":s.display_info.is_primary})).collect())
}
struct Protection(Vec<tauri::WebviewWindow>);
impl Drop for Protection {
    fn drop(&mut self) {
        for w in &self.0 {
            let _ = w.set_content_protected(false);
        }
    }
}
#[tauri::command]
pub async fn capture_preview(app: AppHandle, id: String, display: Option<u32>) -> Res<Value> {
    tauri::async_runtime::spawn_blocking(move||{
        let _restore=Protection(app.webview_windows().into_values().collect::<Vec<_>>());for w in &_restore.0{w.set_content_protected(true).map_err(|e|e.to_string())?;}
        let screens=Screen::all().map_err(|e|e.to_string())?;
        let screen=screens.iter().find(|s|display.map_or(s.display_info.is_primary,|id|s.display_info.id==id)).or(screens.first()).ok_or("No display found")?;
        let image=screen.capture().map_err(|e|e.to_string())?;
        let state=app.state::<AppState>();let time=state.recording.lock().unwrap().as_ref().filter(|(active,_)|active==&id).map(|(_,r)|r.flags.elapsed());
        domain::meeting_path(&state.store.lock().unwrap(),&id)?;
        let mut bytes=Cursor::new(Vec::new());image::DynamicImage::ImageRgba8(image.clone()).write_to(&mut bytes,image::ImageOutputFormat::Png).map_err(|e|e.to_string())?;
        let token=uuid::Uuid::new_v4().to_string();let value=json!({"token":token,"width":image.width(),"height":image.height(),"url":format!("data:image/png;base64,{}",base64::engine::general_purpose::STANDARD.encode(bytes.into_inner()))});
        *PENDING.get_or_init(||Mutex::new(None)).lock().unwrap()=Some(Pending{token,id,image,time});Ok(value)
    }).await.map_err(|e|e.to_string())?
}
pub fn bounds(width: u32, height: u32, rect: &[u32]) -> Res<(u32, u32, u32, u32)> {
    if rect.len() != 4
        || rect[2] == 0
        || rect[3] == 0
        || rect[0].checked_add(rect[2]).is_none_or(|x| x > width)
        || rect[1].checked_add(rect[3]).is_none_or(|y| y > height)
    {
        return Err("Select a region inside the captured display".into());
    }
    Ok((rect[0], rect[1], rect[2], rect[3]))
}
#[tauri::command]
pub fn discard_capture(token: String) {
    let mut pending = PENDING.get_or_init(|| Mutex::new(None)).lock().unwrap();
    if pending.as_ref().is_some_and(|p| p.token == token) {
        *pending = None;
    }
}
#[tauri::command]
pub async fn save_capture(app: AppHandle, token: String, rect: Option<Vec<u32>>) -> Res<()> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut pending = PENDING.get_or_init(|| Mutex::new(None)).lock().unwrap();
        let p = pending
            .as_ref()
            .filter(|p| p.token == token)
            .ok_or("Screenshot expired; capture again")?;
        let (x, y, w, h) = bounds(
            p.image.width(),
            p.image.height(),
            &rect.unwrap_or(vec![0, 0, p.image.width(), p.image.height()]),
        )?;
        let cropped = image::imageops::crop_imm(&p.image, x, y, w, h).to_image();
        let state = app.state::<AppState>();
        let store = state.store.lock().unwrap();
        let dir = domain::meeting_path(&store, &p.id)?;
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let temp = dir.join(format!("capture-{}.png", p.token));
        cropped.save(&temp).map_err(|e| e.to_string())?;
        let result = domain::attach(&store, &p.id, &temp, p.time);
        let _ = std::fs::remove_file(temp);
        result?;
        *pending = None;
        let _ = app.emit("library-changed", ());
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[cfg(test)]
mod tests {
    #[test]
    fn rejects_out_of_screen_and_overflow() {
        assert!(super::bounds(100, 80, &[10, 20, 90, 60]).is_ok());
        assert!(super::bounds(100, 80, &[90, 0, 20, 20]).is_err());
        assert!(super::bounds(100, 80, &[u32::MAX, 0, 2, 2]).is_err());
        assert!(super::bounds(100, 80, &[0, 0, 0, 1]).is_err());
    }
}
