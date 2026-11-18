# Suporte Appelsoft — personalização e atualização

| Arquivo | Para quê |
|---|---|
| `apply_branding.py` | Usado pelo workflow `custom-windows.yml` para gerar os executáveis com a marca. |
| `instalar-cliente.ps1` | Instala o cliente na máquina, define senha permanente, mostra o ID e configura a atualização automática. |
| `atualizar-cliente.ps1` | Atualizador. Fica em `C:\ProgramData\SuporteAppelsoft\` e roda como SYSTEM pela tarefa `SuporteAppelsoft - Atualizador` (1x ao dia entre 09h e 17h + no boot). |
| `publicar-versao.ps1` | Gera o `versao.json` (versão + SHA-256) de um `.exe` novo e mostra os comandos para subir na VPS. |

## Como o atualizador decide

1. Lê `https://remoto.appelsoft.com.br/download/versao.json` → `{versao, sha256, url}`.
2. Atualiza só se `versao` for **maior** que a instalada (`versao-instalada.txt`, versão do `.exe` e do registro; vale a maior).
3. Só baixa de `https://remoto.appelsoft.com.br`, sem redirecionamento.
4. Confere o SHA-256. **Divergiu = apaga o arquivo e não executa nada.**
5. Se alguém estiver conectado na máquina, adia para a próxima execução.
6. Roda `--silent-install` por cima (mantém ID e senha), espera o serviço responder o ID e grava a versão.

Log: `C:\ProgramData\SuporteAppelsoft\atualizador.log`. A pasta só aceita escrita de SYSTEM e Administradores.

## Publicar versão nova

1. Gere o cliente no GitHub Actions (`custom-windows.yml`, `app_name=SuporteAppelsoft`, `conn_type=incoming`) e baixe o `.exe`.
2. Escolha um número **maior** que o publicado. O RustDesk fica em `1.5.3`; para rebuild use o 4º número: `1.5.3.1`, `1.5.3.2`... Ao subir de RustDesk (ex.: 1.5.4), use `1.5.4` ou maior.
3. Rode:
   ```powershell
   .\custom\publicar-versao.ps1 -Exe "C:\Downloads\SuporteAppelsoft-1.5.3-x86_64.exe" -Versao 1.5.3.1
   ```
4. Copie e rode os comandos `scp`/`ssh` que ele mostra (envia com nome temporário, confere o hash na VPS e troca exe e json).
5. Confira: `curl.exe -s https://remoto.appelsoft.com.br/download/versao.json`.

As máquinas pegam a versão nova em até um dia (ou no próximo boot).

## Testar numa máquina de teste

1. Instale com o script novo (o `atualizar-cliente.ps1` precisa estar na mesma pasta):
   ```powershell
   .\instalar-cliente.ps1 -Instalador "https://remoto.appelsoft.com.br/download/cliente"
   ```
   Confira a tarefa: `Get-ScheduledTask "SuporteAppelsoft - Atualizador"`.
2. **Versão fake**: publique na VPS um `versao.json` com versão maior e o hash do `cliente.exe` que já está lá (o mesmo exe):
   ```powershell
   .\custom\publicar-versao.ps1 -Exe "<o mesmo cliente.exe publicado>" -Versao 1.5.3.9
   ```
   e rode só o `scp` do json + o `mv` dele (ou todo o passo 2, que reenvia o mesmo exe).
3. Na máquina de teste, rode a tarefa na hora e veja o log:
   ```powershell
   Start-ScheduledTask "SuporteAppelsoft - Atualizador"
   Get-Content C:\ProgramData\SuporteAppelsoft\atualizador.log -Tail 20 -Wait
   ```
   Esperado: `Atualização disponível ... SHA-256 conferido ... Atualizado para 1.5.3.9. ID ...`. O ID e a senha continuam os mesmos.
4. Rode de novo: deve registrar `Em dia`.
5. **Teste de hash errado**: publique um json com versão `1.5.3.10` e um `sha256` qualquer (64 hex). O log deve mostrar `SHA-256 DIVERGENTE ... nada executado` e a máquina continua na 1.5.3.9.
6. No fim, publique o `versao.json` correto (versão real, maior que as fakes usadas, ex.: `1.5.3.11`) para não deixar as máquinas presas a um hash errado.

> Cuidado: enquanto o json fake estiver publicado, **todas** as máquinas com atualizador vão ler ele. Faça o teste antes de distribuir o instalador novo, ou volte o json logo depois.
