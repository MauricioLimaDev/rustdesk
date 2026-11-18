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

  Atualização automática: copia o atualizar-cliente.ps1 (precisa estar na mesma
  pasta deste script) para C:\ProgramData\SuporteAppelsoft\ e cria a tarefa agendada
  "SuporteAppelsoft - Atualizador" (SYSTEM, 1x ao dia + no boot). Use -SemAtualizador
  para não criar.
#>
param(
    [Parameter(Mandatory = $true)][string]$Instalador,
    [string]$Senha,
    [string]$NomeApp = "SuporteAppelsoft",
    [switch]$SemAtualizador
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
$instalouAgora = -not (Test-Path $exe)
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

# 6. Atualizador automático
function Set-AclSomenteAdmins([string]$Caminho) {
    # Só SYSTEM e Administradores escrevem; Usuários só leem. Sem herança.
    # Evita que um usuário comum troque o script ou o instalador que roda como SYSTEM.
    # Dono = Administradores (se a pasta já existia criada por outro usuário)
    & icacls $Caminho /setowner "*S-1-5-32-544" /T /C /Q | Out-Null
    $itens = @(Get-Item $Caminho -Force) + @(Get-ChildItem $Caminho -Recurse -Force)
    foreach ($item in $itens) {
        # ACL nova do zero: descarta qualquer permissão explícita ou herdada que existia
        if ($item.PSIsContainer) {
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $heranca = [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
        } else {
            $acl = New-Object Security.AccessControl.FileSecurity
            $heranca = [Security.AccessControl.InheritanceFlags]::None
        }
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($p in @(@("S-1-5-18", "FullControl"), @("S-1-5-32-544", "FullControl"), @("S-1-5-32-545", "ReadAndExecute"))) {
            $sid = New-Object Security.Principal.SecurityIdentifier $p[0]
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $sid, $p[1], $heranca, "None", "Allow"))
        }
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
    }
}

if (-not $SemAtualizador) {
    $origem = Join-Path $PSScriptRoot "atualizar-cliente.ps1"
    if (-not (Test-Path $origem)) {
        Write-Host "atualizar-cliente.ps1 não está ao lado deste script: atualização automática NÃO configurada." -ForegroundColor Yellow
    } else {
        $pastaDados = Join-Path $env:ProgramData $NomeApp
        New-Item -ItemType Directory -Path $pastaDados -Force | Out-Null
        Set-AclSomenteAdmins $pastaDados
        $script = Join-Path $pastaDados "atualizar-cliente.ps1"
        Copy-Item $origem $script -Force
        Set-AclSomenteAdmins $pastaDados

        # Se o instalador usado é exatamente o publicado, grava a versão para não reinstalar à toa.
        if ($instalouAgora) { try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $pub = Invoke-RestMethod -Uri "https://remoto.appelsoft.com.br/download/versao.json" -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 30
            $hashInst = (Get-FileHash $Instalador -Algorithm SHA256).Hash
            if ($pub.sha256 -and $hashInst -eq ([string]$pub.sha256).Trim().ToUpperInvariant() -and ([string]$pub.versao) -match '^\d+(\.\d+){1,3}$') {
                Set-Content -Path (Join-Path $pastaDados "versao-instalada.txt") -Value $pub.versao -Encoding ASCII
                Write-Host "Versão publicada $($pub.versao) registrada."
            }
        } catch {
            Write-Host "Não consegui consultar a versão publicada (sem problema; o atualizador confere depois)." -ForegroundColor Yellow
        } }

        $nomeTarefa = "$NomeApp - Atualizador"
        $acao = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
        # Diário entre 09:00 e 17:00 (horário sorteado pelo Windows) + no boot com atraso sorteado por máquina
        $diario = New-ScheduledTaskTrigger -Daily -At "09:00" -RandomDelay (New-TimeSpan -Hours 8)
        $boot = New-ScheduledTaskTrigger -AtStartup
        $boot.Delay = "PT{0}M" -f (Get-Random -Minimum 5 -Maximum 31)
        $config = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $nomeTarefa -Action $acao -Trigger @($diario, $boot) -Settings $config `
            -Principal $principal -Description "Atualiza o $NomeApp a partir de https://remoto.appelsoft.com.br (confere SHA-256)." -Force | Out-Null
        Write-Host "Atualização automática configurada (tarefa '$nomeTarefa')."
    }
}

# 7. Resultado
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
