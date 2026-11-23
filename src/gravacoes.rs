//! Manutenção da pasta de gravações (Suporte Appelsoft):
//! - recompacta as gravações terminadas com o ffmpeg que vai ao lado do exe
//!   (H.264, descarta só quadros idênticos de tela parada; o FPS das partes que mudam fica igual);
//! - apaga as gravações mais antigas que o limite de dias (mínimo 30).
//! Roda numa thread de fundo da janela principal, a cada 10 minutos.

use hbb_common::{anyhow::anyhow, bail, config::LocalConfig, log, ResultType};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, SystemTime},
};

pub const OPCAO_RECOMPACTAR: &str = "gravacao-recompactar";
pub const OPCAO_DIAS: &str = "gravacao-dias";
pub const DIAS_MINIMO: u64 = 30;
const INTERVALO: Duration = Duration::from_secs(10 * 60);
// Gravação sem escrita há menos que isso pode estar em andamento.
const IDADE_MINIMA: Duration = Duration::from_secs(2 * 60);
const SUFIXO: &str = "_c";

static INICIADO: AtomicBool = AtomicBool::new(false);

pub fn recompactar_ligado() -> bool {
    LocalConfig::get_option(OPCAO_RECOMPACTAR) != "N"
}

pub fn dias() -> u64 {
    LocalConfig::get_option(OPCAO_DIAS)
        .trim()
        .parse::<u64>()
        .unwrap_or(DIAS_MINIMO)
        .max(DIAS_MINIMO)
}

pub fn ffmpeg() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let nome = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
    let p = exe.parent()?.join(nome);
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}

pub fn iniciar() {
    if INICIADO.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(60));
        let mut falhas = HashSet::new();
        loop {
            manutencao(&mut falhas);
            std::thread::sleep(INTERVALO);
        }
    });
}

fn nome(p: &Path) -> (String, String) {
    let stem = p
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let ext = p
        .extension()
        .map(|s| s.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    (stem, ext)
}

fn eh_video(p: &Path) -> bool {
    let (_, ext) = nome(p);
    p.is_file() && (ext == "mp4" || ext == "webm")
}

#[cfg(windows)]
fn em_uso(p: &Path) -> bool {
    use std::os::windows::fs::OpenOptionsExt;
    // Sem compartilhamento: falha se o gravador ainda estiver com o arquivo aberto.
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(0)
        .open(p)
        .is_err()
}

#[cfg(not(windows))]
fn em_uso(_p: &Path) -> bool {
    false
}

fn manutencao(falhas: &mut HashSet<PathBuf>) {
    let dir = crate::ui_interface::video_save_directory(false);
    if dir.is_empty() {
        return;
    }
    let Ok(entradas) = std::fs::read_dir(PathBuf::from(&dir)) else {
        return;
    };
    let limite = Duration::from_secs(dias() * 24 * 3600);
    let agora = SystemTime::now();
    let mut pendentes = Vec::new();
    for e in entradas.flatten() {
        let p = e.path();
        if !eh_video(&p) {
            continue;
        }
        let idade = e
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|m| agora.duration_since(m).ok())
            .unwrap_or_default();
        let (stem, _) = nome(&p);
        if idade > limite {
            match std::fs::remove_file(&p) {
                Ok(_) => log::info!("Gravação antiga apagada: {:?}", p),
                Err(err) => log::warn!("Não apagou a gravação antiga {:?}: {}", p, err),
            }
            continue;
        }
        if idade < IDADE_MINIMA {
            continue;
        }
        if stem.ends_with(".part") {
            // Sobra de uma recompactação interrompida.
            if !em_uso(&p) {
                std::fs::remove_file(&p).ok();
            }
            continue;
        }
        if !stem.ends_with(SUFIXO) && !falhas.contains(&p) {
            pendentes.push(p);
        }
    }
    if !recompactar_ligado() {
        return;
    }
    let Some(ffmpeg) = ffmpeg() else {
        return;
    };
    for p in pendentes {
        if !recompactar_ligado() {
            break;
        }
        if em_uso(&p) {
            continue;
        }
        if let Err(err) = recompactar(&ffmpeg, &p) {
            log::warn!("Recompactação falhou {:?}: {}", p, err);
            falhas.insert(p);
        }
    }
}

fn recompactar(ffmpeg: &Path, p: &Path) -> ResultType<()> {
    let (stem, ext) = nome(p);
    let dir = p.parent().ok_or_else(|| anyhow!("sem pasta"))?;
    let tmp = dir.join(format!("{stem}{SUFIXO}.part.mp4"));
    let saida = dir.join(format!("{stem}{SUFIXO}.mp4"));
    std::fs::remove_file(&tmp).ok();

    let mut cmd = Command::new(ffmpeg);
    cmd.args(["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i"])
        .arg(p)
        .args([
            "-map",
            "0:v:0",
            // mpdecimate: tira só os quadros iguais ao anterior (tela parada);
            // scale: o H.264 exige largura e altura pares.
            "-vf",
            "mpdecimate,scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-fps_mode",
            "vfr",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "30",
            "-pix_fmt",
            "yuv420p",
            "-threads",
            "2",
            "-movflags",
            "+faststart",
        ])
        .arg(&tmp)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS: sem janela e sem disputar CPU com a sessão.
        cmd.creation_flags(0x0800_0000 | 0x0000_4000);
    }
    let out = cmd.output()?;
    if !out.status.success() {
        std::fs::remove_file(&tmp).ok();
        let erro: String = String::from_utf8_lossy(&out.stderr).chars().take(300).collect();
        bail!("ffmpeg: {}", erro.trim());
    }
    let novo = std::fs::metadata(&tmp).map(|m| m.len()).unwrap_or(0);
    let antigo = std::fs::metadata(p)?.len();
    if novo == 0 || novo >= antigo {
        // Não ficou menor: mantém o original e marca como já processado.
        std::fs::remove_file(&tmp).ok();
        std::fs::rename(p, dir.join(format!("{stem}{SUFIXO}.{ext}")))?;
        log::info!("Gravação mantida sem recompactar (não reduziu): {:?}", p);
        return Ok(());
    }
    std::fs::rename(&tmp, &saida)?;
    std::fs::remove_file(p)?;
    log::info!(
        "Gravação recompactada: {:?} {} MB -> {} MB",
        saida,
        antigo / 1_048_576,
        novo / 1_048_576
    );
    Ok(())
}
