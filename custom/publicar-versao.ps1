<#
.SYNOPSIS
  Prepara a publicação de uma versão nova do cliente Suporte Appelsoft:
  gera o versao.json (versão + SHA-256 + URL) e mostra os comandos para
  enviar à VPS. Não envia nada sozinho.

.USO
  .\publicar-versao.ps1 -Exe "C:\Downloads\SuporteAppelsoft-1.5.3-x86_64.exe" -Versao 1.5.3.1
  .\publicar-versao.ps1 -Exe ... -Versao 1.5.4 -SshDestino root@187.53.122.51

  -Versao: 2 a 4 números (ex.: 1.5.3.1). Precisa ser MAIOR que a publicada,
  senão as máquinas não atualizam. Para rebuild do mesmo RustDesk (1.5.3),
  use o 4º número: 1.5.3.1, 1.5.3.2...
#>
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Versao,
    [string]$SshDestino = "root@187.53.122.51",
    [string]$PastaVps = "~/rustdesk/downloads",
    [string]$Saida = (Join-Path $env:TEMP "SuporteAppelsoft-publicar")
)

$ErrorActionPreference = "Stop"
$Dominio = "remoto.appelsoft.com.br"
$Url = "https://$Dominio/download/cliente"
$PastaSftp = $PastaVps -replace '^~/', ''   # o sftp não expande ~ (caminho relativo à home)

if ($Versao -notmatch '^\d+(\.\d+){1,3}$') {
    Write-Host "Versão inválida: '$Versao'. Use 2 a 4 números, ex.: 1.5.3.1" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Exe)) {
    Write-Host "Arquivo não encontrado: $Exe" -ForegroundColor Red
    exit 1
}
$Exe = (Resolve-Path $Exe).Path
if ($Exe -match 'Equipe') {
    Write-Host "Isso parece a versão da EQUIPE. O link público é só do cliente." -ForegroundColor Red
    exit 1
}

# Compara com a versão publicada hoje
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $atual = Invoke-RestMethod -Uri "https://$Dominio/download/versao.json" -UseBasicParsing -TimeoutSec 30
    Write-Host "Publicada hoje: $($atual.versao)"
    if ([version]$Versao -le [version]([string]$atual.versao)) {
        Write-Host "A versão $Versao não é maior que a publicada ($($atual.versao)). As máquinas NÃO vão atualizar." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "Ainda não há versao.json publicado (ou a VPS não respondeu). Seguindo." -ForegroundColor Yellow
}

$hash = (Get-FileHash -Path $Exe -Algorithm SHA256).Hash.ToLowerInvariant()
$json = [ordered]@{ versao = $Versao; sha256 = $hash; url = $Url } | ConvertTo-Json

New-Item -ItemType Directory -Path $Saida -Force | Out-Null
$arqJson = Join-Path $Saida "versao.json"
# JSON sem BOM
[IO.File]::WriteAllText($arqJson, $json + "`n", (New-Object Text.UTF8Encoding $false))

Write-Host ""
Write-Host "versao.json gerado em $arqJson" -ForegroundColor Green
Write-Host $json
Write-Host ""
Write-Host "=== Publicar na VPS (rode na ordem) ===" -ForegroundColor Cyan
Write-Host "# 1. Envia com nome temporário (as máquinas não veem arquivo pela metade)"
Write-Host "scp `"$Exe`" ${SshDestino}:$PastaVps/cliente.exe.novo"
Write-Host "scp `"$arqJson`" ${SshDestino}:$PastaVps/versao.json.novo"
Write-Host ""
Write-Host "# 2. Confere o hash lá e troca os arquivos (exe primeiro, json por último)"
Write-Host "ssh $SshDestino `"cd $PastaVps && echo '$hash  cliente.exe.novo' | sha256sum -c - && { cp -f cliente.exe cliente.exe.anterior 2>/dev/null || true; } && mv -f cliente.exe.novo cliente.exe && { cp -f versao.json versao.json.anterior 2>/dev/null || true; } && mv -f versao.json.novo versao.json && ls -l`""
Write-Host ""
Write-Host "# 3. Confere de fora"
Write-Host "curl.exe -s https://$Dominio/download/versao.json"
Write-Host ""
Write-Host "# Alternativa com SFTP (passo 1):"
Write-Host "sftp $SshDestino"
Write-Host "  put `"$Exe`" $PastaSftp/cliente.exe.novo"
Write-Host "  put `"$arqJson`" $PastaSftp/versao.json.novo"
Write-Host "  bye"
Write-Host ""
Write-Host "# Voltar à versão anterior (se der problema):"
Write-Host "ssh $SshDestino `"cd $PastaVps && mv -f cliente.exe.anterior cliente.exe && mv -f versao.json.anterior versao.json`""
Write-Host "  (as máquinas já atualizadas só voltam se você publicar a anterior com número MAIOR)" -ForegroundColor Yellow
