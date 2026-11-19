"""Aplica a personalização do cliente antes do build.

Lê do ambiente:
  APP_NAME           nome do aplicativo (ex.: "Appel Suporte")
  RENDEZVOUS_SERVER  IP ou domínio do servidor hbbs
  RS_PUB_KEY         conteúdo do id_ed25519.pub do servidor

Ícone: se existir custom/icon.png (de preferência 512x512, fundo transparente),
gera os .ico/.png do Windows e da interface. Se existir custom/logo.png,
ele aparece no topo da tela inicial (máx. 300x60 na tela).
"""
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CUSTOM = ROOT / "custom"


def fail(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    sys.exit(1)


def sub_once(path, pattern, repl):
    text = path.read_text(encoding="utf-8")
    new, n = re.subn(pattern, lambda _: repl, text, count=1, flags=re.M)
    if n != 1:
        fail(f"padrão não encontrado em {path.relative_to(ROOT)}: {pattern}")
    path.write_text(new, encoding="utf-8")


def rs_str(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    app_name = os.environ.get("APP_NAME", "").strip()
    display_name = os.environ.get("DISPLAY_NAME", "").strip() or app_name
    conn_type = os.environ.get("CONN_TYPE", "").strip()
    server = os.environ.get("RENDEZVOUS_SERVER", "").strip()
    key = os.environ.get("RS_PUB_KEY", "").strip()
    if not app_name:
        fail("APP_NAME vazio")
    # Mesma regra do instalador (src/platform/mod.rs): sem espaço nem acento.
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*", app_name):
        fail(f"APP_NAME '{app_name}' inválido: use só letras, números, hífen e _ (sem espaço)")
    if conn_type not in ("", "incoming", "outgoing"):
        fail(f"CONN_TYPE '{conn_type}' inválido: use incoming, outgoing ou vazio")
    if not server:
        fail("secret RENDEZVOUS_SERVER não cadastrado")
    if not key:
        fail("secret RS_PUB_KEY não cadastrado")
    if "id_ed25519" in key or "PRIVATE" in key.upper():
        fail("RS_PUB_KEY parece não ser a chave pública")

    cfg = ROOT / "libs/hbb_common/src/config.rs"
    sub_once(cfg, r'RwLock::new\("RustDesk"\.to_owned\(\)\)',
             f'RwLock::new("{rs_str(app_name)}".to_owned())')
    sub_once(cfg, r'^pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[.*\];',
             f'pub const RENDEZVOUS_SERVERS: &[&str] = &["{rs_str(server)}"];')
    sub_once(cfg, r'^pub const RS_PUB_KEY: &str = ".*";',
             f'pub const RS_PUB_KEY: &str = "{rs_str(key)}";')
    if conn_type:
        # incoming = só recebe acesso (cliente); outgoing = só conecta (equipe)
        sub_once(cfg,
                 r'pub static ref HARD_SETTINGS: RwLock<HashMap<String, String>> = Default::default\(\);',
                 'pub static ref HARD_SETTINGS: RwLock<HashMap<String, String>> = '
                 f'RwLock::new(HashMap::from([("conn-type".to_owned(), "{conn_type}".to_owned())]));')

    api_server = os.environ.get("API_SERVER", "").strip().rstrip("/")
    if api_server:
        if not re.fullmatch(r"https?://[A-Za-z0-9.\-]+(:\d+)?", api_server):
            fail(f"API_SERVER '{api_server}' inválido (ex.: https://suporte.exemplo.com.br)")
        # Sem isso, como o servidor está embutido (não configurado), o cliente
        # cai no padrão https://admin.rustdesk.com para login e livro de endereços.
        sub_once(ROOT / "src/common.rs",
                 r'^    "https://admin\.rustdesk\.com"\.to_owned\(\)$',
                 f'    "{rs_str(api_server)}".to_owned()')
        print(f"API embutida: {api_server}")

    if os.environ.get("SKIP_LEGACY_SECURE_TCP") == "1":
        # O hbbs oficial (OSS) não faz a troca de chave TCP. Com o usuário logado
        # na API (token), o cliente exige essa troca e a conexão morre por timeout.
        # A sessão entre as máquinas continua criptografada de ponta a ponta;
        # só a sinalização com o hbbs fica sem a camada extra.
        sub_once(ROOT / "src/client.rs",
                 r'if !exchanged && legacy_secure \{',
                 'if !exchanged && legacy_secure && false {')
        # Mesmo caso no pedido de relay: sem isso, quem está logado espera 18 s pela
        # troca de chave, o pedido nunca chega ao hbbr e dá "deadline has elapsed".
        sub_once(ROOT / "src/client.rs",
                 r'if !key\.is_empty\(\) && \(!token\.is_empty\(\) \|\| !switch_code\.is_empty\(\)\) \{',
                 'if !key.is_empty() && (!token.is_empty() || !switch_code.is_empty()) && false {')
        print("Troca de chave legada com o hbbs desativada (login com API).")

    if conn_type == "outgoing" and api_server:
        # Só-saída não registra no hbbs (ninguém acessa o PC do técnico) e, por isso,
        # também não mandava presença à API. Aqui a presença (heartbeat/sysinfo) é
        # iniciada antes do laço, sem registrar no hbbs: o PC aparece em
        # "Meus dispositivos" e "Dispositivos", mas continua sem aceitar acessos.
        sub_once(ROOT / "src/rendezvous_mediator.rs",
                 r'        if config::is_outgoing_only\(\) \{\r?\n            loop \{',
                 '        if config::is_outgoing_only() {\n'
                 '            crate::hbbs_http::sync::start();\n'
                 '            loop {')
        # Sem serviço instalado, o só-saída fica com stop-service = Y, e o laço de
        # presença pulava todo envio por causa disso.
        sub_once(ROOT / "src/hbbs_http/sync.rs",
                 r'if config::option2bool\("stop-service", &Config::get_option\("stop-service"\)\) \{',
                 'if !config::is_outgoing_only() && config::option2bool("stop-service", &Config::get_option("stop-service")) {')
        print("Só-saída com presença na API ativada.")

    if os.environ.get("AUTO_RECORD_OUTGOING") == "1":
        # Grava toda sessão de saída. Fica em OVERWRITE_LOCAL_SETTINGS: vale sempre,
        # não pode ser salvo diferente e a tela mostra a opção travada.
        sub_once(cfg,
                 r'pub static ref OVERWRITE_LOCAL_SETTINGS: RwLock<HashMap<String, String>> = Default::default\(\);',
                 'pub static ref OVERWRITE_LOCAL_SETTINGS: RwLock<HashMap<String, String>> = '
                 'RwLock::new(HashMap::from([("allow-auto-record-outgoing".to_owned(), "Y".to_owned())]));')
        print("Gravação automática das sessões de saída ligada e travada.")

    # A desinstalação grava stop-service = Y na configuração do usuário, que fica
    # no PC. Numa reinstalação o instalador lia esse Y e não criava o serviço
    # (aparecia "Iniciar serviço"). Instalar passa a sempre zerar a opção, então o
    # serviço é criado com início automático; o botão continua lá se algo falhar.
    sub_once(ROOT / "src/platform/windows.rs",
             r'^    let uninstall_str = get_uninstall\(false, false\)\?;',
             '    Config::set_option("stop-service".into(), "".into());\n'
             '    let uninstall_str = get_uninstall(false, false)?;')
    print("Instalação sempre cria o serviço (ignora stop-service antigo).")

    if os.environ.get("ATUALIZADOR") == "1":
        # O workflow põe atualizar.ps1 e atualizacao.json junto do exe. A instalação
        # registra a tarefa do atualizador; a desinstalação apaga a tarefa.
        sub_once(ROOT / "src/platform/windows.rs",
                 r'^\{after_install\}\r?\n\{sleep\}$',
                 '{after_install}\n'
                 r'if exist \"{path}\\atualizar.ps1\" powershell -NoProfile -NonInteractive '
                 r'-ExecutionPolicy Bypass -WindowStyle Hidden -File \"{path}\\atualizar.ps1\" -Registrar'
                 '\n{sleep}')
        sub_once(ROOT / "src/platform/windows.rs",
                 r'run_cmds\(get_uninstall\(kill_self, true\)\?, true, "uninstall"\)',
                 r'run_cmds(format!("schtasks /delete /tn \"{} - Atualizador\" /f\n{}", '
                 r'crate::get_app_name(), get_uninstall(kill_self, true)?), true, "uninstall")')
        print("Atualizador automático registrado na instalação.")

    # Não deixa conectar no próprio ID (barra de ID, favoritos, livro de endereços:
    # tudo passa por connect() do common.dart).
    sub_once(ROOT / "flutter/lib/common.dart",
             r'^  id = await bind\.mainHandleRelayId\(id: id\);',
             '  id = await bind.mainHandleRelayId(id: id);\n'
             "  if (id.split('@').first == (await bind.mainGetMyId()).replaceAll(' ', '')) {\n"
             "    showToast(translate('cannot_connect_own_id'));\n"
             '    return;\n'
             '  }')
    for lang, texto in [("en", "You cannot connect to your own ID."),
                        ("pt_BR", "Não é possível conectar no seu próprio ID.")]:
        sub_once(ROOT / f"src/lang/{lang}.rs", r'^    \[$',
                 f'    [\n        ("cannot_connect_own_id", "{texto}"),')
    print("Conexão ao próprio ID bloqueada.")

    rc = ROOT / "flutter/windows/runner/Runner.rc"
    sub_once(rc, r'VALUE "FileDescription", "RustDesk Remote Desktop"',
             f'VALUE "FileDescription", "{display_name}"')
    sub_once(rc, r'VALUE "ProductName", "RustDesk"',
             f'VALUE "ProductName", "{display_name}"')

    icon = CUSTOM / "icon.png"
    if icon.exists():
        from PIL import Image

        img = Image.open(icon).convert("RGBA")
        if img.width != img.height:
            side = max(img.width, img.height)
            canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
            canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
            img = canvas
        sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
        for ico in ["res/icon.ico", "res/tray-icon.ico",
                    "flutter/windows/runner/resources/app_icon.ico"]:
            img.save(ROOT / ico, format="ICO", sizes=sizes)
        for name, px in [("res/32x32.png", 32), ("res/64x64.png", 64),
                         ("res/128x128.png", 128), ("res/128x128@2x.png", 256),
                         ("res/icon.png", 512), ("flutter/assets/icon.png", 512)]:
            px = min(px, img.width)  # não amplia além do original
            img.resize((px, px), Image.LANCZOS).save(ROOT / name)
        # Ícone do app no Mac (Finder/Dock)
        icns = ROOT / "flutter/macos/Runner/AppIcon.icns"
        if icns.exists():
            side = 1024 if img.width >= 1024 else 512
            img.resize((side, side), Image.LANCZOS).save(icns, format="ICNS")
        print("Ícone aplicado.")
    else:
        print("custom/icon.png não existe: mantendo o ícone original.")

    logo = CUSTOM / "logo.png"
    if logo.exists():
        shutil.copy(logo, ROOT / "flutter/assets/logo.png")
        print("Logo aplicado.")

    print(f"Personalização aplicada: nome='{app_name}', exibição='{display_name}', "
          f"modo='{conn_type or 'completo'}', servidor='{server}'.")


if __name__ == "__main__":
    main()
