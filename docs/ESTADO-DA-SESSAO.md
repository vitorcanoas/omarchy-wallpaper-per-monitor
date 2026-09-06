# Estado da sessão — 06/09/2026, ~10:50

Handoff escrito antes de compactar o contexto. Para outro Claude (ou para o
Vitor) retomar sem reconstruir nada.

## Situação AGORA (verificada, não suposta)

- Plugin **`vitorcanoas.background-per-monitor`** instalado em
  `~/.config/omarchy/plugins/` e **ativo em produção**. Validado por log:
  `useOverride=true` nas duas telas, `DP-2` 1920x1080 e `HDMI-A-1` 1080x1920.
- Plugin antigo `vitorcanoas.background` **removido de `plugins[]`** no
  `shell.json`, mas preservado no disco (não apagar sem motivo).
- Repo privado no ar: `github.com/vitorcanoas/omarchy-wallpaper-per-monitor`
  (MIT, branch `main`, commit inicial `232c142`, 21 arquivos).
- Wallpapers aplicados: `DP-2` -> `render/16x9/unico-b-rick-morty-battle-dark-8000.png`,
  `HDMI-A-1` -> `render/9x16/retrato-rick-amoled-02.png`.
- Backups do shell.json: `.antes-do-teste-real` e `.bak.20260906-104135`.
- Backup geral (44MB, só local): `~/backup-wallpaper-20260906-1038`.

## EM CURSO quando o contexto foi compactado

Um subagente corrigindo dois bugs achados em teste real:
1. **`install.sh` ignora a variável `HOME`** — rodamos com HOME falso e ele
   escreveu no home REAL (instalou plugin + editou shell.json de verdade).
   Causa provável: uso de `~` (til), que o bash expande pelo /etc/passwd em vez
   de `$HOME`. Correção: `"$HOME"` com aspas em todo caminho.
2. **IPC duplicado**: `Background.qml` registra `IpcHandler` no target
   `background`, que o shell nativo já ocupa. Investigar se é intencional
   (interceptar `omarchy theme bg set`) antes de mudar — mudar pode quebrar a
   integração com o Omarchy.

Esse agente deve commitar local (sem push) e atualizar o CHANGELOG.

## PRÓXIMO PASSO combinado com o Vitor

Code review pesado, 4 frentes em paralelo por subagente, **sobre o commit**
(não sobre o working tree, para não revisar código em movimento):

| Frente | Arquivo | Linhas |
|---|---|---|
| QML: bindings, hotplug, memória com PNG grande | `Background.qml` | 478 |
| Instalador: idempotência, HOME, permissões, falha no meio | `install.sh` | 198 |
| CLIs: quoting, injeção, JSON corrompido, multi-monitor | `bin/wallpaper-monitor` + `bin/wp` | 472 |
| Render: dependências, portabilidade, falha silenciosa | `bin/omarchy-wallpaper-render` | 264 |

Depois: aplicar todas as correções encontradas.

## Pendências menores

- `vitorcanoas.nightlight` saiu do `shell.json` em algum restart de hoje. O
  filtro (`wl-gammarelay-rs`) continua rodando; só o ícone da barra sumiu. Religar.
- `~/Pictures/wallpapers-rick-and-morty/render/_descartados-v2/` tem 20 arquivos
  inúteis (as tarjas da v2). Podem ser apagados.
- Imagens (106MB) ficam fora do repo de propósito, só nesta máquina.
- Sem HD/Drive sincronizado — o backup de 44MB não saiu da máquina.

## Registro externo

- Task ClickUp **`86akdfx1g`** (vence 07/09 18h) — tem comentário com o progresso.
- Doc ClickUp **`2ky4n02j-4413`**, página `2ky4n02j-973` (Produtos › Infra).
- Discord Omarchy BR, canal `#plugins`, post "Wallpaper-per-monitor" (o Vitor já
  corrigiu lá a informação de que o PR do outro dev teria sido recusado — **não
  foi**: PR #10249 está ABERTO).

## Contexto técnico completo

Ver `docs/CONTEXTO.md` (285 linhas) — armadilhas do Real-ESRGAN, bug de binding
QML, issue #8378, semântica de `transform` do Hyprland, regras de plugin.
