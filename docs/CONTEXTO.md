# Contexto técnico — Wallpaper Per Monitor

> Handoff técnico interno. Não é documentação pública (isso é o `README.md`).
> Este documento nasceu de
> `~/Pictures/wallpapers-rick-and-morty/bin/IMPORTAR-NO-OMARCHYVITOR.md`,
> escrito em 06/09/2026 como instrução de importação para o repo
> `omarchyvitor` (branch, `bin/salvar`, etc.). Antes de qualquer importação
> acontecer, a decisão mudou: **este é agora um projeto independente**,
> `omarchy-wallpaper-per-monitor`, publicável por conta própria, espelhando a
> estrutura do projeto irmão `omarchy-nightlight`. O fluxo de import para
> `omarchyvitor` descrito no arquivo original NÃO se aplica mais e foi
> descartado — o conteúdo técnico de fundo (armadilhas, decisões de design,
> onde as imagens ficam) foi migrado e expandido aqui.
>
> Decisão atual (06/09/2026): repositório próprio, local por ora, **sem
> `git init` ainda** — o dono do projeto (Vitor) versiona quando decidir.

## a. Armadilhas técnicas

### `realesrgan-x4plus-anime` é escala fixa 4x

O modelo `realesrgan-x4plus-anime` do Real-ESRGAN só faz upscale em fator 4x.
Passar `-s 2` ou `-s 3` **não retorna erro** — a chamada "funciona" e devolve
uma imagem do tamanho pedido — mas o conteúdo sai corrompido em silêncio
(ladrilhos embaralhados ou emenda deslocada, dependendo do fator). A única
escala segura é `-s 4`; para fatores menores que 4x, a saída de uma passada em
`-s 4` é reduzida depois com filtro Lanczos.

Confirmado no código do motor de render, `bin/omarchy-wallpaper-render`
(originalmente `render-wallpapers-v3.sh`):

```bash
MODEL="realesrgan-x4plus-anime"
...
if realesrgan-ncnn-vulkan -i "$cur" -o "$step" -n "$MODEL" -m "$MODELS" -s 4 -f png >/dev/null 2>&1; then
```

A escala é passada como literal `-s 4`, nunca como variável — não existe
caminho de código no script atual que passe `-s 2` ou `-s 3` para esse
modelo. O comentário no próprio script documenta a armadilha:

> "ARMADILHA: realesrgan-x4plus-anime e' modelo de escala FIXA 4x. -s 2 / -s 3
> nao dao erro mas corrompem o conteudo em silencio. Sempre -s 4, repetindo
> passadas se precisar de mais, reduzindo depois com Lanczos."

O número de passadas de 4x necessárias é calculado em `upscale()` a partir da
razão entre o tamanho necessário e o tamanho de origem; cada passada extra
multiplica o fator por 4 (então 2 passadas cobrem até 16x).

### Bug de binding QML: função no binding não rastreia dependências internas

`property x: minhaFuncao(y)` em QML **nunca reavalia automaticamente** quando
`y` muda, a menos que `y` também seja referenciado diretamente na expressão do
binding. O motor de bindings do QML rastreia apenas as propriedades lidas
durante a avaliação da *expressão* associada à property — quando a expressão é
"chame esta função", o rastreamento para aí; leituras de propriedades feitas
dentro do *corpo* da função chamada não entram na lista de dependências do
binding.

Isso custou uma rodada de debug real durante o desenvolvimento deste plugin: o
log mostrava a função de seleção (`selectOverride`) escolhendo o caminho
correto a cada chamada manual, mas a variável de controle que decide se aquele
caminho é usado (`useOverride`) ficava presa em `false` e nunca virava `true`
quando o JSON de override mudava.

A correção aplicada em `Background.qml` foi declarar `useOverride` como
`readonly property bool` cuja expressão de binding referencia diretamente
`panel.overridePath` e `panel.rejectedOverridePath` — propriedades simples, não
uma chamada de função — para que o QML rastreie a dependência corretamente:

```qml
readonly property bool useOverride: panel.overridePath !== "" && panel.rejectedOverridePath !== panel.overridePath
```

E `overridePath`, por sua vez, é o resultado de `root.selectOverride(...)`
atribuído a uma property (não uma função chamada inline em outro binding), o
que garante que a reavaliação se propaga: quando `backgroundConfig` muda (via
`FileView.onFileChanged` → `reload()` → `onLoaded`), `overridePath` reavalia
porque sua própria expressão de binding lê `root.backgroundConfig` e
`modelData.name` diretamente, e `useOverride`/`baseSource` reavaliam em cadeia
por dependerem de `overridePath` do mesmo jeito direto. A lição geral: nunca
esconder uma leitura de propriedade relevante dentro do corpo de uma função
chamada por um binding — sempre promover essa leitura para a expressão do
próprio binding, ou para uma property intermediária cuja expressão a
referencie diretamente.

### `FileView` do Quickshell: `preload` não é o problema

`FileView` já é declarado com `watchChanges: true` em `Background.qml`; a
hipótese de que faltava `preload: true` (ou de que isso resolveria o
"congelamento" do carregamento inicial) já foi **investigada e descartada**.
O problema real do carregamento inicial era outro: sem uma chamada explícita a
`reload()` em `Component.onCompleted`, o `onLoaded` só dispara na primeira
mudança externa do arquivo, deixando `backgroundConfig` travado em `{}` pela
sessão inteira se o JSON já existisse antes do shell subir. A correção foi
`Component.onCompleted: reload()` no próprio `FileView`. **Não reabrir essa
investigação em `preload`.**

### PNG é obrigatório para os wallpapers renderizados

Todo o pipeline de render grava `.png`, nunca `.jpg`/`.jpeg`, para as imagens
finais. JPEG faz *banding* visível em fundos pretos ou quase-pretos — exatamente
o caso mais comum aqui, já que várias artes usam fundo chapado AMOLED. Em tela
OLED/AMOLED, esse banding é ainda mais perceptível porque o preto é preto de
verdade (pixel apagado), sem o ruído de um painel LCD para mascarar o
degradê.

### `magick` é o binário do ImageMagick 7 — não usar `convert`

O motor de render usa o binário `magick` (ImageMagick 7), com fallback para
`convert` apenas se `magick` não existir no sistema:

```bash
MAGICK="magick"
command -v magick >/dev/null 2>&1 || MAGICK="convert"
```

`convert` está **depreciado** no ImageMagick 7 (mantido só por
compatibilidade). Scripts novos não devem introduzir chamadas diretas a
`convert` — usar `magick` diretamente, deixando o fallback como está apenas
para compatibilidade com sistemas que ainda não migraram.

### Issue #8378 do Omarchy: `omarchy-background` sempre remonta por cima

Tanto `omarchy restart shell` quanto `omarchy-update-restart` remontam uma
layer chamada `omarchy-background` por cima de qualquer coisa que esteja
desenhando o papel de parede. Isso **condena** qualquer solução baseada em
`hyprpaper` ou `swww` rodando como daemon externo — essas soluções seriam
simplesmente sobrescritas na próxima remontagem dessa layer, tipicamente sem
aviso nenhum ao usuário (a tela volta ao wallpaper padrão do tema).

É por isso que a solução tem que ser, necessariamente, um plugin do tipo
`service` do próprio Quickshell/Omarchy — que é exatamente o que
`Background.qml` é (`"kinds": ["service"]` no `manifest.json`, declarando a
mesma namespace `WlrLayershell.namespace: "omarchy-background"` que o
Omarchy usa nativamente) — e não um processo externo tentando desenhar por
cima da stack do compositor.

## b. Erro de premissa do motor de render v2

O motor v2 (`render-wallpapers-v2.sh.ref`, mantido só como referência em
`~/Pictures/wallpapers-rick-and-morty/bin/`) partia da premissa de que toda
arte deveria existir nas **duas** orientações — `render/16x9/` e
`render/9x16/` — não importa a orientação nativa da imagem de origem. Para a
orientação que a arte não tinha nativamente, o v2 usava uma técnica
`fit+blur`: encaixava a arte inteira (sem cortar) na dimensão limitante e
preenchia o espaço sobrando com uma cópia borrada e escurecida da própria
arte.

Isso é um **erro de premissa**, não um detalhe de implementação: cada arte do
catálogo nasce OU deitada OU em pé — nenhuma delas foi originalmente composta
para as duas orientações. Forçar a orientação "errada" via `fit+blur` produzia
resultado ruim (o motivo virava uma tarja fina cercada de borrão), e foi
motivo de reclamação real antes da reescrita.

A v3 (script atual, `bin/omarchy-wallpaper-render`) corrige isso na raiz:
renderiza cada arte **só** na orientação em que ela nasceu, conforme
levantamento em `docs/classificacao-de-artes.md` — 15 artes landscape (14
originalmente deitadas + `user-img10-upscaled.png`, quase-quadrada, tratada
como cover em 16x9) e 10 artes portrait (9 originalmente em pé +
`user-img7-upscaled.png`, quase-quadrada, tratada como fit vertical em 9x16).
A técnica `fit+blur` foi **removida completamente** do código: se uma arte
cair fora da faixa de aspecto aceitável para "cover" na sua orientação
classificada, o script emite um aviso alto e segue com cover mesmo assim (a
classificação, não o fallback, é o que deveria ter evitado o caso), em vez de
reintroduzir blur.

## c. Gap do ecossistema: rotação de monitor não é tratada em nenhum shell Quickshell conhecido

Levantamento de ~6 shells Quickshell do ecossistema Omarchy —
DankMaterialShell, noctalia, caelestia, end-4, e mais 2 — não encontrou
**nenhum** que trate rotação de monitor ao decidir layout ou wallpaper. A
causa raiz: a API que o Quickshell expõe para informação de tela
(`ShellScreen`) **não expõe a propriedade `transform` do monitor** — não há
como, a partir da API pública do Quickshell, saber diretamente se uma tela
está fisicamente rotacionada.

Este plugin contorna isso na prática usando `width`/`height` já efetivos (pós-
rotação) que o próprio Quickshell entrega a `PanelWindow`/`modelData` — que
funcionam para decidir portrait vs. landscape — mas isso é um contorno, não a
API correta. Ficou como **oportunidade real de contribuição upstream**, tanto
para o próprio Quickshell (expor `transform` em `ShellScreen`) quanto para os
shells listados (nenhum deles hoje ajusta nada em função de rotação).

## d. Regras de plugin Omarchy

- Plugins **não rodam em sandbox** e **não passam por revisão** — não existe
  marketplace central de aprovação. Um plugin é, na prática, só um
  repositório git instalado via URL: `omarchy plugin add <url>`.
- O namespace `omarchy.*` no campo `id` do manifest é **reservado** — plugins
  de terceiros (como este) não podem usá-lo. Por isso o `id` deste plugin é
  `vitorcanoas.background-per-monitor`, não algo prefixado com `omarchy.`.
- **Symlinks são proibidos dentro da pasta do plugin instalado**
  (`~/.config/omarchy/plugins/<id>/`). É por isso que instaladores como
  `install.sh` populam essa pasta com `rsync`/`cp`, nunca com `ln -s`.
- Isso NÃO se aplica ao comando de terminal: o symlink que `install.sh` cria
  em `~/.local/bin/` (para expor `wallpaper-monitor`, `wp` e
  `omarchy-wallpaper-render` no `PATH`) é permitido porque fica **fora** da
  pasta do plugin — a restrição é sobre o conteúdo interno do plugin
  instalado, não sobre atalhos de PATH que apontam para dentro dele.

## e. Semântica de `transform` do Hyprland

`hyprctl monitors -j` reporta um campo `transform` por monitor, com valores de
0 a 7:

| valor | significado |
|---|---|
| 0 | normal |
| 1 | rotacionado 90° |
| 2 | rotacionado 180° |
| 3 | rotacionado 270° |
| 4 | espelhado (flipped) |
| 5 | espelhado + 90° |
| 6 | espelhado + 180° |
| 7 | espelhado + 270° |

**Valores ímpares (1, 3, 5, 7) invertem largura e altura** visualmente — o
monitor gira um quarto de volta (ou três quartos), então o que era largura
física passa a ser altura lógica na tela, e vice-versa.

**Pegadinha central**: `hyprctl monitors -j` reporta as dimensões **físicas**
do modo de vídeo (ex.: `1920x1080` para um monitor Full HD), **não** as
dimensões lógicas já rotacionadas. Um monitor `1920x1080` com `transform: 1`
está, na prática, exibindo uma área lógica de `1080x1920` (portrait) — mas o
JSON de `hyprctl monitors` continua dizendo `1920x1080`. Qualquer código que
decida orientação (retrato vs. paisagem) a partir dessas dimensões **sem
considerar `transform`** vai errar exatamente nos monitores rotacionados, que
são o caso de uso central deste plugin.

Correção aplicada em `bin/wp` (função `mon_por_orientacao`): inverte `width` e
`height` quando `transform % 2` é ímpar, antes de comparar para decidir
portrait/landscape:

```python
w, h = (m['height'], m['width']) if m['transform'] % 2 else (m['width'], m['height'])
```

Já `Background.qml`, do lado do Quickshell, não sofre desse problema: o
`width`/`height` que a `PanelWindow` recebe do `modelData` já vêm como
dimensões efetivas pós-rotação (documentado no próprio código: "HDMI-A-1
chega como 1080x1920 quando em retrato"). A pegadinha é especificamente da
API crua do `hyprctl`, usada pelos CLIs em bash, não da API do Quickshell.

## f. Onde as imagens ficam

`~/Pictures/wallpapers-rick-and-morty/` (~106MB no total), mantido **de
propósito fora deste repositório** — não deve ser versionado. É gosto pessoal
(wallpapers de Rick and Morty) e infla todo `git clone` do projeto sem
nenhum benefício para quem só quer o plugin.

Estrutura relevante dentro dessa pasta:

- `render/16x9/` — 15 imagens já renderizadas, landscape (1920x1080).
- `render/9x16/` — 10 imagens já renderizadas, portrait (1080x1920).
- `_descartados-v2/` — imagens (por volta de 20) com tarjas pretas resultantes
  da técnica `fit+blur` da v2, movidas para lá pelo próprio script de render
  (função `limpa_orfaos_v2`) em vez de apagadas. São candidatas a remoção
  definitiva por serem obsoletas — a v3 não usa mais `fit+blur` e não deveria
  gerar novos arquivos ali.

Os CLIs (`wp`, `wallpaper-monitor`) e o motor de render, agora copiados para
`bin/` deste repositório, continuam operando sobre essa pasta de imagens (via
caminho relativo ao próprio script, `$(dirname "$0")/..`, no caso do motor de
render) ou recebendo caminhos absolutos de imagem como argumento (no caso de
`wallpaper-monitor set`). Nenhuma imagem em si faz parte deste repositório.

## g. Registro no ClickUp

Contexto completo registrado no ClickUp: Doc `2ky4n02j-4413`, página
`2ky4n02j-973`, Space "Produtos" › Folder "Infra".

## h. Origem deste documento

Este handoff nasceu de
`~/Pictures/wallpapers-rick-and-morty/bin/IMPORTAR-NO-OMARCHYVITOR.md`,
escrito em 06/09/2026 antes de se decidir manter este trabalho como projeto
independente — originalmente ele descrevia um fluxo de importação para o
repositório `omarchyvitor` (branch `wallpaper-por-monitor` a partir de `main`,
script `bin/salvar`, arquivo `manifesto/plugins-locais.txt`). Esse fluxo **não
se aplica mais**: a decisão atual (06/09/2026) é manter
`omarchy-wallpaper-per-monitor` como repositório próprio e independente, local
por ora — **sem `git init` ainda** — com o dono do projeto (Vitor) decidindo
quando e como versionar. Este arquivo substitui o handoff original como
registro técnico de referência do projeto.
