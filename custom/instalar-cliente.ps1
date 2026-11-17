<#
.SYNOPSIS
  Instala o Suporte Appelsoft numa máquina de cliente, define uma senha
  permanente própria da máquina e mostra o ID para cadastro.

.USO (PowerShell como administrador)
  .\instalar-cliente.ps1 -Instalador "C:\caminho\Suporte-Appelsoft-1.5.3-x86_64.exe"
  .\instalar-cliente.ps1 -Instalador "https://seu-servidor/Suporte-Appelsoft.exe"
  .\instalar-cliente.ps1 -Instalador ... -Senha "SenhaEscolhida123"

  Sem -Senha, gera uma senha aleatória de 12 caracteres.
  O servidor e a chave já vêm embutidos no executável: não precisa configurar nada.
#>
param(
    [Parameter(Mandatory = $true)][string]$Instalador,
    [string]$Senha,
    [string]$NomeApp = "Suporte Appelsoft"
)

$ErrorActionPreference = "Stop"

# 1. Precisa ser administrador
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "Abra o PowerShell como administrador e rode de novo." -ForegroundColor Red
    exit 1
}

# 2. Baixa o instalador se for URL
if ($Instalador -match '^https?://') {
    $destino = Join-Path $env:TEMP "suporte-appelsoft-setup.exe"
    Write-Host "Baixando o instalador..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Instalador -OutFile $destino -UseBasicParsing
    $Instalador = $destino
}
if (-not (Test-Path $Instalador)) {
    Write-Host "Instalador não encontrado: $Instalador" -ForegroundColor Red
    exit 1
}

# 3. Instalação silenciosa
$exe = Join-Path $env:ProgramFiles "$NomeApp\$NomeApp.exe"
if (Test-Path $exe) {
    Write-Host "Já instalado em $exe. Pulando a instalação."
} else {
    Write-Host "Instalando $NomeApp..."
    Start-Process -FilePath $Instalador -ArgumentList "--silent-install" -Wait
    $limite = (Get-Date).AddMinutes(3)
    while (-not (Test-Path $exe) -and (Get-Date) -lt $limite) { Start-Sleep -Seconds 3 }
    if (-not (Test-Path $exe)) {
        Write-Host "A instalação não terminou em 3 minutos. Confira se o antivírus bloqueou." -ForegroundColor Red
        exit 1
    }
}

# 4. Espera o serviço subir
Write-Host "Aguardando o serviço iniciar..."
$limite = (Get-Date).AddMinutes(2)
do {
    Start-Sleep -Seconds 3
    $id = (& $exe --get-id | Out-String).Trim()
} while ([string]::IsNullOrWhiteSpace($id) -and (Get-Date) -lt $limite)

if ([string]::IsNullOrWhiteSpace($id)) {
    Write-Host "Não consegui ler o ID. Abra o $NomeApp e confira se ele conecta no servidor." -ForegroundColor Red
    exit 1
}

# 5. Senha permanente (única por máquina)
if (-not $Senha) {
    # sem caracteres ambíguos (0/O, 1/l/I)
    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789".ToCharArray()
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 12
    $rng.GetBytes($bytes)
    $Senha = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}
$resultado = (& $exe --password $Senha | Out-String).Trim()
if ($resultado -notmatch "Done") {
    Write-Host "Falha ao definir a senha: $resultado" -ForegroundColor Red
    exit 1
}

# 6. Resultado
$maquina = $env:COMPUTERNAME
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " $NomeApp instalado"                        -ForegroundColor Green
Write-Host " Máquina: $maquina"
Write-Host " ID:      $id"
Write-Host " Senha:   $Senha"
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Anote o ID e a senha no seu cadastro. A senha não fica salva em arquivo."

try { "Máquina: $maquina`r`nID: $id`r`nSenha: $Senha" | Set-Clipboard; Write-Host "(copiado para a área de transferência)" } catch {}
