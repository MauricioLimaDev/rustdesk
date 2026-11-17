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
    server = os.environ.get("RENDEZVOUS_SERVER", "").strip()
    key = os.environ.get("RS_PUB_KEY", "").strip()
    if not app_name:
        fail("APP_NAME vazio")
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

    rc = ROOT / "flutter/windows/runner/Runner.rc"
    sub_once(rc, r'VALUE "FileDescription", "RustDesk Remote Desktop"',
             f'VALUE "FileDescription", "{app_name}"')
    sub_once(rc, r'VALUE "ProductName", "RustDesk"',
             f'VALUE "ProductName", "{app_name}"')

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
        print("Ícone aplicado.")
    else:
        print("custom/icon.png não existe: mantendo o ícone original.")

    logo = CUSTOM / "logo.png"
    if logo.exists():
        shutil.copy(logo, ROOT / "flutter/assets/logo.png")
        print("Logo aplicado.")

    print(f"Personalização aplicada: nome='{app_name}', servidor='{server}'.")


if __name__ == "__main__":
    main()
