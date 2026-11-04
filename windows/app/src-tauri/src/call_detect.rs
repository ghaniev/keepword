use crate::{settings, AppState};
use std::{collections::HashSet, sync::atomic::Ordering, time::Duration};
use tauri::{AppHandle, Emitter, Manager};
use windows::{
    core::{Interface, PWSTR},
    Win32::{
        Foundation::CloseHandle,
        Media::Audio::*,
        System::{Com::*, Threading::*},
    },
};
unsafe fn active_apps() -> windows::core::Result<Vec<String>> {
    let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
    let device = enumerator.GetDefaultAudioEndpoint(eCapture, eCommunications)?;
    let manager: IAudioSessionManager2 = device.Activate(CLSCTX_ALL, None)?;
    let sessions = manager.GetSessionEnumerator()?;
    let mut apps = HashSet::new();
    for i in 0..sessions.GetCount()? {
        let session = sessions.GetSession(i)?;
        if session.GetState()? != AudioSessionStateActive {
            continue;
        }
        let session: IAudioSessionControl2 = session.cast()?;
        let pid = session.GetProcessId()?;
        if pid == 0 || pid == std::process::id() {
            continue;
        }
        if let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            let mut buffer = [0u16; 4096];
            let mut len = buffer.len() as u32;
            let result = QueryFullProcessImageNameW(
                process,
                PROCESS_NAME_WIN32,
                PWSTR(buffer.as_mut_ptr()),
                &mut len,
            );
            let _ = CloseHandle(process);
            if result.is_ok() {
                let path = String::from_utf16_lossy(&buffer[..len as usize]);
                let lower = path.to_lowercase();
                if [
                    "zoom", "teams", "chrome", "msedge", "firefox", "slack", "discord", "webex",
                ]
                .iter()
                .any(|name| lower.contains(name))
                {
                    apps.insert(
                        std::path::Path::new(&path)
                            .file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .into_owned(),
                    );
                }
            }
        }
    }
    Ok(apps.into_iter().collect())
}
pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        // COM objects are created and released on this monitoring thread.
        let initialized = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).is_ok() };
        if !initialized {
            return;
        }
        let mut previous = Vec::new();
        let mut misses = 0;
        loop {
            let state = app.state::<AppState>();
            if state.shutdown.load(Ordering::Relaxed) {
                break;
            }
            let enabled =
                settings::load(&state.store.lock().unwrap().dir).is_ok_and(|s| s.call_detection);
            if enabled {
                let mut apps = unsafe { active_apps() }.unwrap_or_default();
                apps.sort();
                if apps.is_empty() {
                    misses += 1;
                } else {
                    misses = 0;
                }
                if !apps.is_empty() && apps != previous {
                    let _ = app.emit(
                        "call-detected",
                        serde_json::json!({"apps":apps,"active":true}),
                    );
                    previous = apps;
                } else if misses >= 3 && !previous.is_empty() {
                    let _ = app.emit(
                        "call-detected",
                        serde_json::json!({"apps":previous,"active":false}),
                    );
                    previous.clear();
                }
            }
            std::thread::sleep(Duration::from_secs(3));
        }
        unsafe { CoUninitialize() };
    });
}
