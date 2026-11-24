// Reiniciar o serviço do Windows pela tela do Cliente.
//
// Quando o Cliente fica "Não está pronto" por um tempo, a tela mostra o link
// "Reiniciar serviço". O clique abre este mesmo executável elevado (UAC) com
// --reiniciar-servico, que para o serviço, encerra o que sobrou dele e inicia de
// novo. Sem cmd nem PowerShell: só o próprio app chamando o sc do Windows.

use hbb_common::log;
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::time::{Duration, Instant};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// sc devolve 1060 quando o serviço não existe.
const SERVICO_NAO_EXISTE: i32 = 1060;

fn sc(args: &[&str]) -> Option<i32> {
    match Command::new("sc")
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    {
        Ok(o) => o.status.code(),
        Err(e) => {
            log::error!("sc {:?}: {}", args, e);
            None
        }
    }
}

fn esperar(rodando: bool, limite: Duration) -> bool {
    let inicio = Instant::now();
    while inicio.elapsed() < limite {
        if crate::platform::is_self_service_running() == rodando {
            return true;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    crate::platform::is_self_service_running() == rodando
}

/// Chamado pela tela: pede elevação e roda --reiniciar-servico.
/// Devolve false se o usuário recusou o UAC ou se o app não está instalado.
pub fn pedir_reinicio() -> bool {
    if !crate::platform::is_installed() {
        return false;
    }
    let exe = match std::env::current_exe() {
        Ok(p) => p.to_string_lossy().to_string(),
        Err(_) => return false,
    };
    log::info!("Pedido de reinício do serviço pela tela");
    crate::platform::run_uac(&exe, "--reiniciar-servico").unwrap_or(false)
}

/// Roda elevado (--reiniciar-servico).
pub fn reiniciar_elevado() {
    let nome = crate::get_app_name();
    log::info!("Reiniciando o serviço {nome}");
    if sc(&["query", &nome]) == Some(SERVICO_NAO_EXISTE) {
        // Serviço sumiu (removido ou instalação incompleta): cria de novo.
        log::warn!("Serviço {nome} não existe, recriando");
        crate::platform::install_service();
        return;
    }
    if crate::platform::is_self_service_running() {
        sc(&["stop", &nome]);
        if !esperar(false, Duration::from_secs(20)) {
            log::warn!("Serviço {nome} não parou em 20 s");
        }
    }
    // Processos do serviço (rodam como SYSTEM) que tenham ficado presos.
    let _ = Command::new("taskkill")
        .args(&[
            "/F",
            "/IM",
            &format!("{nome}.exe"),
            "/FI",
            "USERNAME eq SYSTEM",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    std::thread::sleep(Duration::from_secs(1));
    sc(&["start", &nome]);
    if esperar(true, Duration::from_secs(20)) {
        log::info!("Serviço {nome} reiniciado");
    } else {
        log::error!("Serviço {nome} não voltou a rodar");
    }
}
