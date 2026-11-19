#!/usr/bin/env bash
# Publica um build na VPS (chamado pelos workflows custom-windows.yml e custom-macos.yml).
#
#   publicar-vps.sh <windows|mac> <cliente|equipe> <versao> <arquivo>
#
# Secrets (env): VPS_HOST, VPS_USER, VPS_SSH_KEY; ATUALIZADOR_CHAVE em CHAVE (só equipe).
# Sem os secrets da VPS, só avisa e não falha o build.
#
# Na VPS (~/rustdesk/downloads):
#   cliente windows -> cliente.exe + versao.json            (link público /download/cliente)
#   equipe  windows -> equipe.exe (painel) + a/<CHAVE>/equipe.exe + a/<CHAVE>/versao.json
#   equipe  mac     -> equipe-mac-arm64.dmg (painel)
# Envia com nome temporário, confere o SHA-256 lá e só então troca (o json por último).
set -euo pipefail

PLATAFORMA="$1"; CANAL="$2"; VERSAO="$3"; ARQ="$4"
BASE="https://remoto.appelsoft.com.br/download"
PASTA="rustdesk/downloads"   # relativo à home do usuário SSH

if [ -z "${VPS_HOST:-}" ] || [ -z "${VPS_USER:-}" ] || [ -z "${VPS_SSH_KEY:-}" ]; then
  echo "::warning::Secrets VPS_HOST/VPS_USER/VPS_SSH_KEY não configurados: build não publicado na VPS."
  exit 0
fi
[ -f "$ARQ" ] || { echo "::error::Arquivo não encontrado: $ARQ"; exit 1; }
if [ "$CANAL" = "equipe" ] && ! [[ "${CHAVE:-}" =~ ^[A-Za-z0-9]{32,}$ ]]; then
  echo "::error::Secret ATUALIZADOR_CHAVE ausente ou inválido."; exit 1
fi

mkdir -p ~/.ssh
KEY=~/.ssh/vps_deploy
printf '%s\n' "$VPS_SSH_KEY" | tr -d '\r' > "$KEY"
chmod 600 "$KEY"
ssh-keyscan -T 20 "$VPS_HOST" >> ~/.ssh/known_hosts 2>/dev/null
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=30)
DEST="$VPS_USER@$VPS_HOST"

HASH=$(sha256sum "$ARQ" | cut -d' ' -f1)
TMP=".upload-$PLATAFORMA-$CANAL"
echo "Publicando $CANAL ($PLATAFORMA) versão $VERSAO, sha256 $HASH"

scp "${SSH_OPTS[@]}" "$ARQ" "$DEST:$PASTA/$TMP.bin"

case "$PLATAFORMA/$CANAL" in
  windows/cliente)
    printf '{"versao": "%s", "sha256": "%s", "url": "%s"}\n' "$VERSAO" "$HASH" "$BASE/cliente" > versao.json
    scp "${SSH_OPTS[@]}" versao.json "$DEST:$PASTA/$TMP.json"
    REMOTO="
      cp -f $TMP.bin cliente.exe.novo && mv -f cliente.exe.novo cliente.exe &&
      { cp -f versao.json versao.json.anterior 2>/dev/null || true; } &&
      mv -f $TMP.json versao.json"
    ;;
  windows/equipe)
    printf '{"versao": "%s", "sha256": "%s", "url": "%s"}\n' "$VERSAO" "$HASH" "$BASE/a/$CHAVE/equipe.exe" > versao.json
    scp "${SSH_OPTS[@]}" versao.json "$DEST:$PASTA/$TMP.json"
    REMOTO="
      mkdir -p a/$CHAVE && chmod 755 a a/$CHAVE &&
      cp -f $TMP.bin equipe.exe.novo && mv -f equipe.exe.novo equipe.exe &&
      cp -f $TMP.bin a/$CHAVE/equipe.exe.novo && mv -f a/$CHAVE/equipe.exe.novo a/$CHAVE/equipe.exe &&
      mv -f $TMP.json a/$CHAVE/versao.json"
    ;;
  mac/equipe)
    REMOTO="cp -f $TMP.bin equipe-mac-arm64.dmg.novo && mv -f equipe-mac-arm64.dmg.novo equipe-mac-arm64.dmg"
    ;;
  *)
    echo "::error::Combinação não suportada: $PLATAFORMA/$CANAL"; exit 1 ;;
esac

ssh "${SSH_OPTS[@]}" "$DEST" "set -e; cd $PASTA &&
  echo '$HASH  $TMP.bin' | sha256sum -c - &&
  $REMOTO &&
  rm -f $TMP.bin &&
  chmod 644 *.exe *.json *.dmg 2>/dev/null; true"

echo "Publicado na VPS: $CANAL ($PLATAFORMA) $VERSAO"
