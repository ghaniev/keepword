// No console window in release builds on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod asr;
mod call_detect;
mod capture;
mod cloud_asr;
mod commands;
mod diarize;
mod domain;
mod embed;
mod llm;
mod local_llm;
mod mcp;
mod models;
mod pipeline;
mod recorder;
mod schedule;
mod settings;
mod store;
mod subprocess;

use recorder::{Mode, Recorder};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::Ordering::Relaxed;
use std::sync::{Arc, Mutex};
use store::{Meeting, Store};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, State};

struct AppState {
    store: Mutex<Store>,
    recording: Mutex<Option<(String, Recorder)>>,
    processing: Mutex<Option<String>>,
    cancelled: std::sync::atomic::AtomicBool,
    shutdown: std::sync::atomic::AtomicBool,
    downloading: std::sync::atomic::AtomicBool,
    download_cancelled: std::sync::atomic::AtomicBool,
}

type Res<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// %LOCALAPPDATA%\MeetNotes: recordings are large, so not the roaming profile.
/// Same layout as ~/Library/Application Support/MeetNotes on macOS.
fn data_dir_path(app: &AppHandle) -> tauri::Result<PathBuf> {
    // A separate library makes Windows smoke checks safe for existing personal data.
    let override_dir = std::env::args_os()
        .skip_while(|arg| arg != "--library-path")
        .nth(1);
    let dir = match override_dir {
        Some(path) => PathBuf::from(path),
        None => app.path().local_data_dir()?.join("MeetNotes"),
    };
    std::fs::create_dir_all(dir.join("recordings"))?;
    Ok(dir)
}

#[tauri::command]
fn data_dir(state: State<AppState>) -> String {
    state.store.lock().unwrap().dir.display().to_string()
}

#[tauri::command]
fn list_meetings(state: State<AppState>) -> Res<Vec<Meeting>> {
    state.store.lock().unwrap().meetings().map_err(err)
}

#[tauri::command]
fn input_devices() -> Vec<String> {
    recorder::input_devices()
}

#[derive(Serialize)]
struct Started {
    id: String,
    warning: Option<String>,
}

#[tauri::command]
async fn start_recording(
    app: AppHandle,
    title: String,
    mode: Mode,
    mic: Option<String>,
) -> Res<Started> {
    tauri::async_runtime::spawn_blocking(move || start_recording_inner(app, title, mode, mic))
        .await
        .map_err(err)?
}

fn start_recording_inner(
    app: AppHandle,
    title: String,
    mode: Mode,
    mic: Option<String>,
) -> Res<Started> {
    let state = app.state::<AppState>();
    let mut recording = state.recording.lock().unwrap();
    if recording.is_some() {
        return Err("Already recording".into());
    }
    let store = state.store.lock().unwrap();
    let id = store.new_meeting(&title).map_err(err)?;
    let events = app.clone();
    let sink: recorder::Sink = Arc::new(move |e| {
        let _ = events.emit("recorder", e);
    });
    match Recorder::start(&store.meeting_dir(&id), mode, mic, sink) {
        Ok((rec, warning)) => {
            *recording = Some((id.clone(), rec));
            Ok(Started { id, warning })
        }
        Err(e) => {
            let _ = store.set_status(&id, &format!("error:{e}"));
            Err(e)
        }
    }
}

#[tauri::command]
async fn stop_recording(app: AppHandle) -> Res<()> {
    tauri::async_runtime::spawn_blocking(move || finish_recording(app.state::<AppState>()))
        .await
        .map_err(err)?
}

fn finish_recording(state: State<AppState>) -> Res<()> {
    let mut recording = state.recording.lock().unwrap();
    let Some((id, rec)) = recording.take() else {
        return Ok(());
    };
    let result = rec.stop();
    let store = state.store.lock().unwrap();
    let duration = match result {
        Ok(duration) => duration,
        Err(e) => {
            store.set_status(&id, &format!("error:{e}")).map_err(err)?;
            return Err(e);
        }
    };
    store.set_duration(&id, duration).map_err(err)?;
    // Transcription picks up "queued" meetings (phase 3).
    store.set_status(&id, "queued").map_err(err)
}

#[tauri::command]
fn set_paused(state: State<AppState>, paused: bool) {
    if let Some((_, rec)) = state.recording.lock().unwrap().as_ref() {
        rec.flags.set_paused(paused);
    }
}

#[tauri::command]
fn set_mic_muted(state: State<AppState>, muted: bool) {
    if let Some((_, rec)) = state.recording.lock().unwrap().as_ref() {
        rec.flags.mic_muted.store(muted, Relaxed);
    }
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

fn main() {
    tauri::Builder::default()
        // A second launch focuses the running app instead of opening another one.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main(app)
        }))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let dir = data_dir_path(app.handle())?;
            settings::configure_secret_store(&dir);
            app.asset_protocol_scope()
                .allow_directory(dir.join("recordings"), true)?;
            let store = Store::open(&dir)?;
            app.manage(AppState {
                store: Mutex::new(store),
                recording: Mutex::new(None),
                processing: Mutex::new(None),
                cancelled: false.into(),
                shutdown: false.into(),
                downloading: false.into(),
                download_cancelled: false.into(),
            });
            pipeline::start(app.handle().clone());
            call_detect::start(app.handle().clone());
            schedule::start(app.handle().clone());
            if let Err(e) = mcp::server(app.handle().clone()) {
                eprintln!("MCP server: {e}");
            }
            let show = MenuItem::with_id(app, "show", "Open MeetNotes", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("MeetNotes")
                .menu(&Menu::with_items(app, &[&show, &quit])?)
                .on_menu_event(|app, e| match e.id.as_ref() {
                    "show" => show_main(app),
                    "quit" => {
                        // Close the WAV files properly before exiting.
                        app.exit(0)
                    }
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Closing the window keeps the recorder alive; Quit in the tray exits explicitly.
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            data_dir,
            list_meetings,
            input_devices,
            start_recording,
            stop_recording,
            set_paused,
            set_mic_muted,
            commands::view_data,
            commands::edit_data,
            commands::preferences,
            commands::save_preferences,
            commands::model_status,
            commands::download_models,
            commands::cancel_download,
            commands::process_meeting,
            commands::cancel_processing,
            commands::import_media,
            commands::media_paths,
            commands::export_markdown,
            commands::add_attachment,
            commands::attachment_files,
            commands::reveal_attachment,
            commands::send_chat,
            commands::new_chat,
            commands::new_note,
            commands::test_provider,
            commands::choose_directory,
            commands::choose_executable,
            commands::recording_state,
            commands::person_meetings,
            commands::tag_meetings,
            commands::calendar_feeds,
            commands::list_calendar_feeds,
            commands::remove_calendar_feed,
            commands::add_calendar_feed,
            commands::record_event,
            commands::open_privacy,
            commands::show_overlay,
            commands::run_query,
            commands::mcp_tools,
            commands::mcp_call,
            commands::mcp_info,
            commands::screenshot,
            capture::capture_displays,
            capture::capture_preview,
            capture::save_capture,
            capture::discard_capture,
            commands::open_external,
            commands::download_local_model,
            commands::check_update,
            commands::install_update
        ])
        .build(tauri::generate_context!())
        .expect("error while building MeetNotes")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                app.state::<AppState>().shutdown.store(true, Relaxed);
                app.state::<AppState>().cancelled.store(true, Relaxed);
                if let Err(e) = finish_recording(app.state::<AppState>()) {
                    eprintln!("Could not finish recording: {e}");
                }
            }
        });
}
