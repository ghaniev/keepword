use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
};
use tauri::{AppHandle, Emitter};

const REV: &str = "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce";
const FILES: [(&str, u64, &str); 4] = [
    (
        "encoder-model.int8.onnx",
        652183999,
        "6139d2fa7e1b086097b277c7149725edbab89cc7c7ae64b23c741be4055aff09",
    ),
    (
        "decoder_joint-model.int8.onnx",
        18202004,
        "eea7483ee3d1a30375daedc8ed83e3960c91b098812127a0d99d1c8977667a70",
    ),
    (
        "nemo128.onnx",
        139764,
        "a9fde1486ebfcc08f328d75ad4610c67835fea58c73ba57e3209a6f6cf019e9f",
    ),
    (
        "vocab.txt",
        93939,
        "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
    ),
];
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub file: String,
    pub downloaded: u64,
    pub total: u64,
}

pub fn directory(library: &Path) -> PathBuf {
    library.join("Models/parakeet-tdt-0.6b-v3")
}
pub fn ready(library: &Path) -> bool {
    FILES.iter().all(|(name, size, _)| {
        fs::metadata(directory(library).join(name)).is_ok_and(|m| m.len() == *size)
    })
}
pub fn sha256(path: &Path) -> Result<String, String> {
    let mut f = File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = f.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn download(library: &Path, app: &AppHandle, cancelled: &AtomicBool) -> Result<(), String> {
    let dir = directory(library);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    for (name, size, hash) in FILES {
        let url = format!(
            "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/{REV}/{name}"
        );
        artifact(&url, &dir.join(name), size, hash, app, cancelled)?;
    }
    download_speakers(library, app, cancelled)?;
    let embed = library.join("Models/minilm");
    fs::create_dir_all(&embed).map_err(|e| e.to_string())?;
    artifact("https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/resolve/e8f8c211226b894fcb81acc59f3b34ba3efd5f42/onnx/model.onnx",&embed.join("model.onnx"),470301610,"10f7a088420252b26caf819236ca2c9d2987afd0fc06fec7553b542a5655a05a",app,cancelled)?;
    artifact("https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/resolve/e8f8c211226b894fcb81acc59f3b34ba3efd5f42/tokenizer.json",&embed.join("tokenizer.json"),9081518,"2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8",app,cancelled)
}

pub fn speakers_ready(library: &Path) -> bool {
    let dir = library.join("Models/diarization");
    dir.join("model.int8.onnx").is_file() && dir.join("embedding.onnx").is_file()
}
pub fn artifact(
    url: &str,
    path: &Path,
    size: u64,
    hash: &str,
    app: &AppHandle,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let mut last = std::time::Instant::now() - std::time::Duration::from_secs(1);
    transfer(url, path, size, hash, cancel, |downloaded| {
        if last.elapsed().as_millis() >= 150 || downloaded == size {
            let _ = app.emit(
                "model-download",
                Progress {
                    file: path
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned(),
                    downloaded,
                    total: size,
                },
            );
            last = std::time::Instant::now();
        }
    })
}
fn transfer(
    url: &str,
    path: &Path,
    size: u64,
    hash: &str,
    cancel: &AtomicBool,
    mut progress: impl FnMut(u64),
) -> Result<(), String> {
    if path.is_file()
        && fs::metadata(path).map_err(|e| e.to_string())?.len() == size
        && sha256(path)? == hash
    {
        return Ok(());
    }
    let part = path.with_extension("part");
    let mut offset = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if offset > size || offset == size && sha256(&part)? != hash {
        fs::remove_file(&part).map_err(|e| e.to_string())?;
        offset = 0;
    }
    if offset < size {
        let client = reqwest::blocking::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(20))
            .timeout(std::time::Duration::from_secs(3600))
            .build()
            .map_err(|e| e.to_string())?;
        let mut request = client.get(url);
        if offset > 0 {
            request = request.header("Range", format!("bytes={offset}-"));
        }
        let mut response = request
            .send()
            .and_then(|r| r.error_for_status())
            .map_err(|e| e.to_string())?;
        if response.status() == reqwest::StatusCode::PARTIAL_CONTENT {
            let range = response
                .headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .ok_or("Missing download range")?;
            if !range.starts_with(&format!("bytes {offset}-"))
                || !range.ends_with(&format!("/{size}"))
            {
                return Err("Invalid download range".into());
            }
        } else {
            offset = 0;
        }
        let mut out = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .append(offset > 0)
            .truncate(offset == 0)
            .open(&part)
            .map_err(|e| e.to_string())?;
        let mut buffer = [0u8; 65536];
        progress(offset);
        loop {
            if cancel.load(Ordering::Relaxed) {
                return Err("Download cancelled".into());
            }
            let n = response.read(&mut buffer).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            offset += n as u64;
            if offset > size {
                return Err("Unexpected artifact size".into());
            }
            out.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
            progress(offset);
        }
        out.sync_all().map_err(|e| e.to_string())?;
    }
    if offset != size {
        return Err("Download interrupted; retry to resume".into());
    }
    if sha256(&part)? != hash {
        fs::remove_file(&part).map_err(|e| e.to_string())?;
        return Err("Artifact checksum mismatch; retry to download again".into());
    }
    fs::rename(part, path).map_err(|e| e.to_string())
}

fn download_speakers(library: &Path, app: &AppHandle, cancel: &AtomicBool) -> Result<(), String> {
    let dir = library.join("Models/diarization");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let archive = dir.join("segmentation.tar.bz2");
    artifact("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",&archive,6958444,"24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",app,cancel)?;
    let mut tar = tar::Archive::new(bzip2::read::BzDecoder::new(
        File::open(archive).map_err(|e| e.to_string())?,
    ));
    for entry in tar.entries().map_err(|e| e.to_string())? {
        let mut entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path().map_err(|e| e.to_string())?.into_owned();
        if let Some(name) = path.file_name() {
            if name == "model.int8.onnx" || name == "LICENSE" {
                let mut out = File::create(dir.join(name)).map_err(|e| e.to_string())?;
                std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
            }
        }
    }
    if sha256(&dir.join("model.int8.onnx"))?
        != "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d"
    {
        return Err("Segmentation model checksum mismatch".into());
    }
    artifact("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx",&dir.join("embedding.onnx"),40257283,"ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e",app,cancel)
}

#[cfg(test)]
mod tests {
    #[test]
    fn resumes_partial_artifact_and_checks_content() {
        let dir = std::env::temp_dir().join(format!("resume-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("model.bin");
        std::fs::write(path.with_extension("part"), b"a").unwrap();
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}/model", server.server_addr());
        let worker = std::thread::spawn(move || {
            let request = server.recv().unwrap();
            assert!(request
                .headers()
                .iter()
                .any(|h| h.field.equiv("Range") && h.value.as_str() == "bytes=1-"));
            request
                .respond(
                    tiny_http::Response::from_data(b"bc".to_vec())
                        .with_status_code(206)
                        .with_header(
                            tiny_http::Header::from_bytes("Content-Range", "bytes 1-2/3").unwrap(),
                        ),
                )
                .unwrap();
        });
        super::transfer(
            &url,
            &path,
            3,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            &std::sync::atomic::AtomicBool::new(false),
            |_| {},
        )
        .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"abc");
        worker.join().unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn hashes_file_content() {
        let path = std::env::temp_dir().join(format!("hash-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"abc").unwrap();
        assert_eq!(
            super::sha256(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        std::fs::remove_file(path).unwrap();
    }
}
