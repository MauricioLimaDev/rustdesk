//! Manutenção da pasta de gravações (Suporte Appelsoft):
//! - recompacta as gravações terminadas com o ffmpeg que vai ao lado do exe
//!   (H.264, descarta só quadros idênticos de tela parada; o FPS das partes que mudam fica igual);
//! - apaga as gravações mais antigas que o limite de dias (mínimo 30).
//! Roda numa thread de fundo da janela principal, a cada 10 minutos.
//! Log próprio: <pasta de logs>/gravacoes.log (tempo, tamanho antes/depois, CPU usada, erros).

use hbb_common::{
    anyhow::anyhow,
    bail, chrono,
    config::{Config, LocalConfig},
    log, ResultType,
};
use std::{
    collections::HashSet,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant, SystemTime},
};

pub const OPCAO_RECOMPACTAR: &str = "gravacao-recompactar";
pub const OPCAO_DIAS: &str = "gravacao-dias";
pub const DIAS_MINIMO: u64 = 30;
const INTERVALO: Duration = Duration::from_secs(10 * 60);
// Gravação sem escrita há menos que isso pode estar em andamento.
const IDADE_MINIMA: Duration = Duration::from_secs(2 * 60);
const SUFIXO: &str = "_c";
const MB: f64 = 1_048_576.0;

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

/// Escreve no gravacoes.log (pasta de logs do app) e no log geral.
fn registrar(msg: &str) {
    log::info!("[gravações] {}", msg);
    let dir = Config::log_path();
    std::fs::create_dir_all(&dir).ok();
    let arq = dir.join("gravacoes.log");
    if std::fs::metadata(&arq).map(|m| m.len() > 1_048_576).unwrap_or(false) {
        std::fs::rename(&arq, dir.join("gravacoes.log.old")).ok();
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&arq) {
        let _ = writeln!(f, "{}  {}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"), msg);
    }
}

pub fn iniciar() {
    if INICIADO.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(60));
        registrar(&format!(
            "Manutenção iniciada. Recompactar: {}, ffmpeg: {}, apagar com mais de {} dias.",
            if recompactar_ligado() { "sim" } else { "não" },
            if ffmpeg().is_some() { "sim" } else { "não encontrado" },
            dias()
        ));
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

fn nome_arquivo(p: &Path) -> String {
    p.file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default()
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

/// Tempo de CPU (usuário + kernel) que o processo usou, para medir o peso na máquina.
#[cfg(windows)]
fn tempo_cpu(child: &std::process::Child) -> Option<Duration> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::{
        Foundation::{FILETIME, HANDLE},
        System::Threading::GetProcessTimes,
    };
    let mut criacao = FILETIME::default();
    let mut saida = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut usuario = FILETIME::default();
    let r = unsafe {
        GetProcessTimes(
            HANDLE(child.as_raw_handle()),
            &mut criacao,
            &mut saida,
            &mut kernel,
            &mut usuario,
        )
    };
    r.ok()?;
    let t = |f: FILETIME| ((f.dwHighDateTime as u64) << 32) | f.dwLowDateTime as u64;
    Some(Duration::from_nanos((t(kernel) + t(usuario)) * 100))
}

#[cfg(not(windows))]
fn tempo_cpu(_child: &std::process::Child) -> Option<Duration> {
    None
}

fn hms(segundos: f64) -> String {
    let s = segundos.max(0.0) as u64;
    format!("{:02}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
}

fn manutencao(falhas: &mut HashSet<PathBuf>) {
    let dir = crate::ui_interface::video_save_directory(false);
    if dir.is_empty() {
        return;
    }
    let Ok(entradas) = std::fs::read_dir(PathBuf::from(&dir)) else {
        return;
    };
    let limite_dias = dias();
    let limite = Duration::from_secs(limite_dias * 24 * 3600);
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
                Ok(_) => registrar(&format!(
                    "Apagada (mais de {} dias): {}",
                    limite_dias,
                    nome_arquivo(&p)
                )),
                Err(err) => registrar(&format!(
                    "ERRO ao apagar gravação antiga {}: {}",
                    nome_arquivo(&p),
                    err
                )),
            }
            continue;
        }
        if idade < IDADE_MINIMA {
            continue;
        }
        if stem.ends_with(".part") {
            // Sobra de uma recompactação interrompida (app fechado no meio).
            if !em_uso(&p) && std::fs::remove_file(&p).is_ok() {
                registrar(&format!("Removida sobra de recompactação interrompida: {}", nome_arquivo(&p)));
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
            registrar("Recompactação desligada nas configurações. Parando.");
            break;
        }
        if em_uso(&p) {
            continue;
        }
        if let Err(err) = recompactar(&ffmpeg, &p) {
            registrar(&format!(
                "ERRO ao recompactar {}: {} (não tenta de novo até reabrir o app)",
                nome_arquivo(&p),
                err
            ));
            falhas.insert(p);
        }
    }
}

fn recompactar(ffmpeg: &Path, p: &Path) -> ResultType<()> {
    let (stem, ext) = nome(p);
    let dir = p.parent().ok_or_else(|| anyhow!("sem pasta"))?;
    let tmp = dir.join(format!("{stem}{SUFIXO}.part.mp4"));
    let destino = dir.join(format!("{stem}{SUFIXO}.mp4"));
    std::fs::remove_file(&tmp).ok();
    let antigo = std::fs::metadata(p)?.len();
    registrar(&format!(
        "Recompactando {} ({:.1} MB)...",
        nome_arquivo(p),
        antigo as f64 / MB
    ));

    // Progresso (-progress) e erros vão para arquivos temporários: lidos no fim.
    let base = std::env::temp_dir().join(format!("gravacao-{}", std::process::id()));
    let arq_progresso = base.with_extension("progresso.txt");
    let arq_erro = base.with_extension("erro.txt");
    let mut cmd = Command::new(ffmpeg);
    cmd.args([
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostats",
        "-progress",
        "pipe:1",
        "-y",
        "-i",
    ])
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
    .stdout(Stdio::from(std::fs::File::create(&arq_progresso)?))
    .stderr(Stdio::from(std::fs::File::create(&arq_erro)?));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS: sem janela e sem disputar CPU com a sessão.
        cmd.creation_flags(0x0800_0000 | 0x0000_4000);
    }
    let inicio = Instant::now();
    let mut child = cmd.spawn()?;
    let status = child.wait()?;
    let levou = inicio.elapsed();
    let cpu = tempo_cpu(&child);
    let progresso = std::fs::read_to_string(&arq_progresso).unwrap_or_default();
    let erro = std::fs::read_to_string(&arq_erro).unwrap_or_default();
    std::fs::remove_file(&arq_progresso).ok();
    std::fs::remove_file(&arq_erro).ok();

    if !status.success() {
        std::fs::remove_file(&tmp).ok();
        let erro: String = erro.trim().chars().take(400).collect();
        bail!("ffmpeg saiu com {} depois de {}: {}", status, hms(levou.as_secs_f64()), erro);
    }

    // Duração do vídeo e velocidade: últimos valores do -progress.
    let ultimo = |chave: &str| {
        progresso
            .lines()
            .rev()
            .find_map(|l| l.strip_prefix(chave).map(|v| v.trim().to_owned()))
            .unwrap_or_default()
    };
    let duracao = ultimo("out_time_us=")
        .parse::<f64>()
        .map(|us| hms(us / 1_000_000.0))
        .unwrap_or_else(|_| "?".into());
    let velocidade = ultimo("speed=");
    let peso = match cpu {
        Some(c) if levou.as_secs_f64() > 0.0 => format!(
            "CPU {} ({:.0}% de um núcleo em média)",
            hms(c.as_secs_f64()),
            c.as_secs_f64() / levou.as_secs_f64() * 100.0
        ),
        _ => "CPU ?".into(),
    };

    let novo = std::fs::metadata(&tmp).map(|m| m.len()).unwrap_or(0);
    if novo == 0 || novo >= antigo {
        // Não ficou menor: mantém o original e marca como já processado.
        std::fs::remove_file(&tmp).ok();
        std::fs::rename(p, dir.join(format!("{stem}{SUFIXO}.{ext}")))?;
        registrar(&format!(
            "Mantida sem recompactar (não reduziu: {:.1} MB -> {:.1} MB): {}. Levou {}, {}.",
            antigo as f64 / MB,
            novo as f64 / MB,
            nome_arquivo(p),
            hms(levou.as_secs_f64()),
            peso
        ));
        return Ok(());
    }
    std::fs::rename(&tmp, &destino)?;
    std::fs::remove_file(p)?;
    registrar(&format!(
        "OK {}: {:.1} MB -> {:.1} MB (-{:.0}%). Vídeo {}, levou {} (velocidade {}), {}.",
        nome_arquivo(&destino),
        antigo as f64 / MB,
        novo as f64 / MB,
        (1.0 - novo as f64 / antigo as f64) * 100.0,
        duracao,
        hms(levou.as_secs_f64()),
        if velocidade.is_empty() { "?".into() } else { velocidade },
        peso
    ));
    Ok(())
}
