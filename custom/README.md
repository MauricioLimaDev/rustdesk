# Suporte Appelsoft — personalização e atualização

| Arquivo | Para quê |
|---|---|
| `apply_branding.py` | Aplica nome, ícone, servidor e patches antes do build (`custom-windows.yml`, `custom-macos.yml`). |
| `atualizar.ps1` | Atualizador automático do Cliente e da Equipe. Vai dentro do instalador. |
| `publicar-vps.sh` | Chamado pelo workflow no fim do build: envia o build para a VPS. |
| `instalar-cliente.ps1` | Opcional: instala o cliente, define senha permanente e mostra o ID. |
| `atualizar-cliente.ps1`, `publicar-versao.ps1` | Antigos (atualizador por ProgramData e publicação manual). A versão nova os substitui. |

## Fluxo automático

1. Rode `custom-windows.yml` (ou `custom-macos.yml`) com **Publicar na VPS** marcado (padrão).
2. O build recebe a versão `1.5.3.<nº do build>`, sempre maior que a anterior.
3. No fim, o workflow envia o arquivo para `~/rustdesk/downloads` na VPS, confere o SHA-256 lá e troca:
   - Cliente: `cliente.exe` + `versao.json` (link público `/download/cliente`).
   - Equipe Windows: `equipe.exe` (painel) + `a/<chave>/equipe.exe` + `a/<chave>/versao.json`.
   - Equipe Mac: `equipe-mac-arm64.dmg` (painel; o Mac ainda não se atualiza sozinho).
4. As máquinas Windows pegam a versão nova em até 4 horas (ou 10 a 30 min depois de ligar).

Secrets do repositório: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` (chave só para deploy) e `ATUALIZADOR_CHAVE`
(32+ letras/números; forma o caminho da Equipe). Sem os da VPS, o build termina e só avisa que não publicou.
Trocar a `ATUALIZADOR_CHAVE` deixa as Equipes já instaladas sem atualização até serem reinstaladas.

## Como a máquina se atualiza

- A instalação copia `atualizar.ps1` e `atualizacao.json` (`{versao, canal}`) para `C:\Program Files\<app>\`
  e cria a tarefa `<app> - Atualizador` (SYSTEM, a cada 4 h + no boot). A desinstalação apaga a tarefa.
- O script lê o canal, compara a versão, baixa só de `https://remoto.appelsoft.com.br`, confere o SHA-256
  (divergiu = não executa nada) e roda `--silent-install` por cima (mantém ID, senha e login).
- Com sessão aberta (alguém acessando a máquina ou a Equipe acessando outra), adia.
- Log: `C:\ProgramData\<app>\atualizador.log`.

Testar na hora numa máquina (PowerShell como administrador):
```powershell
Start-ScheduledTask "SuporteAppelsoft - Atualizador"
Get-Content C:\ProgramData\SuporteAppelsoft\atualizador.log -Tail 20 -Wait
```

Voltar uma versão: rode o build de novo a partir do commit anterior (sai com número maior).
