<#
.SYNOPSIS
  Atualizador automático do Suporte Appelsoft (Cliente e Equipe).

.COMO CHEGA NA MÁQUINA
  O build (custom-windows.yml) coloca este script e o atualizacao.json dentro do
  instalador. A instalação copia os dois para a pasta do app (Program Files\<app>,
  onde só administradores escrevem) e roda "atualizar.ps1 -Registrar", que cria a
  tarefa "<app> - Atualizador" (SYSTEM, a cada 4 horas e no boot).
  Não precisa de script de instalação à parte.

.COMO FUNCIONA
  1. atualizacao.json (ao lado deste script) diz a versão instalada e o canal:
       {"versao": "1.5.3.42", "canal": "https://remoto.appelsoft.com.br/download/versao.json"}
  2. Lê o canal -> {versao, sha256, url}. Só aceita https://remoto.appelsoft.com.br.
  3. Se a publicada for maior: baixa, confere o SHA-256 e roda --silent-install.
     Hash divergente = nada é executado.
  4. Não atualiza com sessão aberta (alguém acessando a máquina ou, na Equipe,
     o técnico acessando outra). Tenta de novo na próxima execução.

  Log: C:\ProgramData\<app>\atualizador.log
  Rodar à mão (PowerShell como administrador):
    & "C:\Program Files\SuporteAppelsoft\atualizar.ps1" -Forcar
#>
param(
    # Cria/atualiza a tarefa agendada e sai (chamado pela instalação).
    [switch]$Registrar,
    # Reinstala mesmo se a versão publicada não for maior (teste).
    [switch]$Forcar
)

$ErrorActionPreference = "Stop"

$Dominio    = "remoto.appelsoft.com.br"
$PastaApp   = $PSScriptRoot
$NomeApp    = Split-Path $PastaApp -Leaf
$Exe        = Join-Path $PastaApp "$NomeApp.exe"
$ArqConfig  = Join-Path $PastaApp "atualizacao.json"
$Dados      = Join-Path $env:ProgramData $NomeApp
$Log        = Join-Path $Dados "atualizador.log"
$Download   = Join-Path $Dados "download"
$NomeTarefa = "$NomeApp - Atualizador"
$TamanhoMax = 300MB

function Write-Log([string]$Mensagem) {
    try {
        if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 1MB) {
            Move-Item $Log "$Log.old" -Force
        }
        $linha = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Mensagem
        Add-Content -Path $Log -Value $linha -Encoding UTF8
    } catch {}
    Write-Host $Mensagem
}

function ConvertTo-Versao([string]$Texto) {
    if ($Texto -match '^\s*(\d+(\.\d+){1,3})') { return [version]$Matches[1] }
    return $null
}

function Test-UrlPermitida([string]$Url) {
    try { $u = [Uri]$Url } catch { return $false }
    return ($u.Scheme -eq "https" -and $u.Host -eq $Dominio -and $u.Port -eq 443)
}

function Set-AclSomenteAdmins([string]$Caminho) {
    # Só SYSTEM e Administradores escrevem; Usuários só leem. Sem herança.
    # Impede um usuário comum de trocar o instalador baixado, que roda como SYSTEM.
    & icacls $Caminho /setowner "*S-1-5-32-544" /T /C /Q | Out-Null
    $itens = @(Get-Item $Caminho -Force) + @(Get-ChildItem $Caminho -Recurse -Force)
    foreach ($item in $itens) {
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

function Register-Tarefa {
    $argumentos = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $existente = Get-ScheduledTask -TaskName $NomeTarefa -ErrorAction SilentlyContinue
    if ($existente -and $existente.Actions.Count -eq 1 -and $existente.Actions[0].Arguments -eq $argumentos) {
        # Já aponta para este script. Não mexe (a tarefa pode estar rodando a própria atualização).
        return
    }
    $acao = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $argumentos
    # A cada 4 horas (com até 30 min sorteados por máquina) e 10 a 30 min depois do boot.
    $periodico = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(8) `
        -RepetitionInterval (New-TimeSpan -Hours 4) -RandomDelay (New-TimeSpan -Minutes 30)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = "PT{0}M" -f (Get-Random -Minimum 10 -Maximum 31)
    $config = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $NomeTarefa -Action $acao -Trigger @($periodico, $boot) -Settings $config `
        -Principal $principal -Description "Atualiza o $NomeApp a partir de https://$Dominio (confere SHA-256)." -Force | Out-Null
    Write-Log "Tarefa '$NomeTarefa' registrada."
}

function Test-SessaoAberta {
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name = '$NomeApp.exe'")
        # Alguém acessando esta máquina: o RustDesk abre um processo "--cm".
        if ($procs | Where-Object { $_.CommandLine -match '--cm' }) { return $true }
        # Equipe acessando outra máquina: a sessão roda na janela principal (sem --service,
        # --server, --tray). Com sessão, ela tem conexão TCP aberta fora da 443 (API).
        $ui = @($procs | Where-Object { $_.CommandLine -notmatch '--(service|server|tray|cm)' })
        foreach ($p in $ui) {
            $tcp = @(Get-NetTCPConnection -OwningProcess $p.ProcessId -State Established -ErrorAction SilentlyContinue |
                Where-Object { $_.RemotePort -ne 443 -and $_.RemoteAddress -notmatch '^(127\.|::1$)' })
            if ($tcp.Count -gt 0) { return $true }
        }
    } catch {}
    return $false
}

try {
    New-Item -ItemType Directory -Path $Dados -Force | Out-Null
    Set-AclSomenteAdmins $Dados

    if ($Registrar) {
        Register-Tarefa
        exit 0
    }

    if (-not (Test-Path $Exe))       { Write-Log "Não instalado ($Exe). Nada a fazer."; exit 0 }
    if (-not (Test-Path $ArqConfig)) { Write-Log "Sem $ArqConfig. Nada a fazer."; exit 0 }

    $config = Get-Content $ArqConfig -Raw | ConvertFrom-Json
    $versaoInst = ConvertTo-Versao ([string]$config.versao)
    $canal = [string]$config.canal
    if (-not (Test-UrlPermitida $canal)) { throw "Canal recusado (só https://$Dominio): '$canal'" }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # 1. Versão publicada no canal
    $info = Invoke-RestMethod -Uri $canal -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 60 `
        -Headers @{ "Cache-Control" = "no-cache" }
    $versaoPub = ConvertTo-Versao ([string]$info.versao)
    $hashPub   = ([string]$info.sha256).Trim().ToUpperInvariant()
    $urlPub    = [string]$info.url
    if (-not $versaoPub)                     { throw "Canal sem 'versao' válida: '$($info.versao)'" }
    if ($hashPub -notmatch '^[0-9A-F]{64}$') { throw "Canal sem 'sha256' válido." }
    if (-not (Test-UrlPermitida $urlPub))    { throw "URL recusada (só https://$Dominio): '$urlPub'" }

    # 2. Comparação
    if (-not $Forcar -and $versaoInst -and $versaoPub -le $versaoInst) {
        Write-Log "Em dia. Instalada $versaoInst, publicada $versaoPub."
        exit 0
    }
    Write-Log "Atualização disponível: instalada $versaoInst -> publicada $versaoPub."

    if (Test-SessaoAberta) {
        Write-Log "Há sessão de acesso aberta. Adiado para a próxima execução."
        exit 0
    }

    # 3. Download (pasta protegida)
    if (Test-Path $Download) { Remove-Item $Download -Recurse -Force }
    New-Item -ItemType Directory -Path $Download -Force | Out-Null
    $arquivo = Join-Path $Download "$NomeApp-$versaoPub-setup.exe"
    Write-Log "Baixando a versão $versaoPub ..."
    Invoke-WebRequest -Uri $urlPub -OutFile $arquivo -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 900

    $tamanho = (Get-Item $arquivo).Length
    if ($tamanho -le 0 -or $tamanho -gt $TamanhoMax) { throw "Tamanho inesperado do download: $tamanho bytes." }

    # 4. SHA-256: sem conferir, não executa
    $hashBaixado = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hashBaixado -ne $hashPub) {
        Remove-Item $arquivo -Force -ErrorAction SilentlyContinue
        throw "SHA-256 DIVERGENTE. Esperado $hashPub, baixado $hashBaixado. Arquivo apagado, nada executado."
    }
    Write-Log "SHA-256 conferido."

    if (Test-SessaoAberta) {
        Write-Log "Sessão aberta durante o download. Adiado."
        exit 0
    }

    # 5. Instalação silenciosa por cima (mantém ID, senha e login)
    Write-Log "Instalando com --silent-install ..."
    Start-Process -FilePath $arquivo -ArgumentList "--silent-install" -Wait -WindowStyle Hidden

    # O pacote extrai e chama o instalador interno; espera o atualizacao.json novo e o ID.
    $limite = (Get-Date).AddMinutes(5)
    $id = ""
    $versaoNova = $null
    do {
        Start-Sleep -Seconds 5
        try { $versaoNova = ConvertTo-Versao ([string](Get-Content $ArqConfig -Raw | ConvertFrom-Json).versao) } catch { $versaoNova = $null }
        if ($versaoNova -and $versaoNova -ge $versaoPub) {
            try { $id = (& $Exe --get-id | Out-String).Trim() } catch { $id = "" }
        }
    } while ((-not $versaoNova -or $versaoNova -lt $versaoPub -or [string]::IsNullOrWhiteSpace($id)) -and (Get-Date) -lt $limite)

    if (-not $versaoNova -or $versaoNova -lt $versaoPub) { throw "A versão nova não foi instalada em 5 minutos." }
    if ([string]::IsNullOrWhiteSpace($id)) { throw "Instalado, mas o serviço não respondeu o ID em 5 minutos." }

    Remove-Item $Download -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Atualizado para $versaoNova. ID $id."
    exit 0
}
catch {
    Write-Log "ERRO: $($_.Exception.Message)"
    exit 1
}
