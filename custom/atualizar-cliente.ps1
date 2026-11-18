<#
.SYNOPSIS
  Atualizador automático do Suporte Appelsoft (roda como SYSTEM pela tarefa agendada).

.COMO FUNCIONA
  1. Lê https://remoto.appelsoft.com.br/download/versao.json  -> {versao, sha256, url}
  2. Compara com a versão instalada (arquivo versao-instalada.txt, versão do .exe e do registro).
  3. Se a publicada for maior: baixa só por HTTPS do domínio remoto.appelsoft.com.br,
     confere o SHA-256 e só então roda o instalador com --silent-install.
     Hash divergente = nada é executado.
  4. Não atualiza se houver uma conexão de suporte aberta (tenta de novo na próxima execução).

  Log: C:\ProgramData\SuporteAppelsoft\atualizador.log
  Instalado e agendado pelo instalar-cliente.ps1. Não precisa rodar à mão,
  mas pode (PowerShell como administrador):  .\atualizar-cliente.ps1 -Forcar
#>
param(
    [string]$NomeApp = "SuporteAppelsoft",
    # Reinstala mesmo se a versão publicada não for maior (útil para teste)
    [switch]$Forcar
)

$ErrorActionPreference = "Stop"

$Dominio    = "remoto.appelsoft.com.br"
$UrlVersao  = "https://$Dominio/download/versao.json"
$Pasta      = Join-Path $env:ProgramData $NomeApp
$Log        = Join-Path $Pasta "atualizador.log"
$Estado     = Join-Path $Pasta "versao-instalada.txt"
$Download   = Join-Path $Pasta "download"
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
    # Pega só "1.2.3" ou "1.2.3.4" do começo do texto (ex.: "1.5.3+62" -> 1.5.3)
    if ($Texto -match '^\s*(\d+(\.\d+){1,3})') { return [version]$Matches[1] }
    return $null
}

function Test-UrlPermitida([string]$Url) {
    try { $u = [Uri]$Url } catch { return $false }
    return ($u.Scheme -eq "https" -and $u.Host -eq $Dominio -and $u.Port -eq 443)
}

function Get-VersaoInstalada([string]$Exe) {
    $candidatas = @()
    if (Test-Path $Estado) {
        $candidatas += ConvertTo-Versao (Get-Content $Estado -Raw)
    }
    try { $candidatas += ConvertTo-Versao (Get-Item $Exe).VersionInfo.ProductVersion } catch {}
    try {
        $reg = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$NomeApp"
        $candidatas += ConvertTo-Versao (Get-ItemProperty $reg -ErrorAction Stop).DisplayVersion
    } catch {}
    $candidatas = @($candidatas | Where-Object { $_ })
    if ($candidatas.Count -eq 0) { return $null }
    return ($candidatas | Sort-Object -Descending | Select-Object -First 1)
}

function Test-ConexaoAberta {
    # Com alguém conectado, o RustDesk mantém um processo "--cm" (janela do gerenciador de conexão).
    try {
        $cm = Get-CimInstance Win32_Process -Filter "Name = '$NomeApp.exe'" |
            Where-Object { $_.CommandLine -match '--cm' }
        return [bool]$cm
    } catch { return $false }
}

try {
    New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $exe = Join-Path $env:ProgramFiles "$NomeApp\$NomeApp.exe"
    if (-not (Test-Path $exe)) {
        Write-Log "Não instalado ($exe). Nada a fazer."
        exit 0
    }

    # 1. Versão publicada
    $info = Invoke-RestMethod -Uri $UrlVersao -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 60 `
        -Headers @{ "Cache-Control" = "no-cache" }
    $versaoPub = ConvertTo-Versao ([string]$info.versao)
    $hashPub   = ([string]$info.sha256).Trim().ToUpperInvariant()
    $urlPub    = [string]$info.url

    if (-not $versaoPub)                      { throw "versao.json sem 'versao' válida: '$($info.versao)'" }
    if ($hashPub -notmatch '^[0-9A-F]{64}$')  { throw "versao.json sem 'sha256' válido." }
    if (-not (Test-UrlPermitida $urlPub))     { throw "URL recusada (só https://$Dominio): '$urlPub'" }

    # 2. Comparação
    $versaoInst = Get-VersaoInstalada $exe
    if (-not $Forcar -and $versaoInst -and $versaoPub -le $versaoInst) {
        Write-Log "Em dia. Instalada $versaoInst, publicada $versaoPub."
        exit 0
    }
    Write-Log "Atualização disponível: instalada $versaoInst -> publicada $versaoPub."

    if (Test-ConexaoAberta) {
        Write-Log "Há conexão de suporte aberta. Adiado para a próxima execução."
        exit 0
    }

    # 3. Download (pasta protegida: só SYSTEM e Administradores escrevem)
    if (Test-Path $Download) { Remove-Item $Download -Recurse -Force }
    New-Item -ItemType Directory -Path $Download -Force | Out-Null
    $arquivo = Join-Path $Download "$NomeApp-$versaoPub-setup.exe"

    Write-Log "Baixando $urlPub ..."
    Invoke-WebRequest -Uri $urlPub -OutFile $arquivo -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 900

    $tamanho = (Get-Item $arquivo).Length
    if ($tamanho -le 0 -or $tamanho -gt $TamanhoMax) {
        throw "Tamanho inesperado do download: $tamanho bytes."
    }

    # 4. SHA-256: sem conferir, não executa
    $hashBaixado = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hashBaixado -ne $hashPub) {
        Remove-Item $arquivo -Force -ErrorAction SilentlyContinue
        throw "SHA-256 DIVERGENTE. Esperado $hashPub, baixado $hashBaixado. Arquivo apagado, nada executado."
    }
    Write-Log "SHA-256 conferido ($hashBaixado)."

    # 5. Instalação silenciosa por cima (mantém ID e senha)
    $antes = (Get-Item $exe).LastWriteTimeUtc
    Write-Log "Instalando com --silent-install ..."
    Start-Process -FilePath $arquivo -ArgumentList "--silent-install" -Wait -WindowStyle Hidden

    # O pacote extrai e chama o instalador interno; espera o exe novo e o ID responderem.
    $limite = (Get-Date).AddMinutes(5)
    $id = ""
    do {
        Start-Sleep -Seconds 5
        $trocou = (Test-Path $exe) -and ((Get-Item $exe).LastWriteTimeUtc -ne $antes)
        if ($trocou) {
            try { $id = (& $exe --get-id | Out-String).Trim() } catch { $id = "" }
        }
    } while ((-not $trocou -or [string]::IsNullOrWhiteSpace($id)) -and (Get-Date) -lt $limite)

    if (-not $trocou) { throw "O executável não foi substituído em 5 minutos." }
    if ([string]::IsNullOrWhiteSpace($id)) { throw "Instalado, mas o serviço não respondeu o ID em 5 minutos." }

    Set-Content -Path $Estado -Value $versaoPub.ToString() -Encoding ASCII
    Remove-Item $Download -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Atualizado para $versaoPub. ID $id."
    exit 0
}
catch {
    Write-Log "ERRO: $($_.Exception.Message)"
    exit 1
}
