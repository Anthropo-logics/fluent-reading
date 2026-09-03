# Manual de uso — Leitura Fluída

*[Léelo en español](MANUAL.md) · [Read this in English](MANUAL.en.md)*

Este guia explica como usar a Leitura Fluída passo a passo, sem termos técnicos. Se você procura do
que trata o projeto ou como compilá-lo, isso está no [`README`](README.md).

## Antes de começar

- A Leitura Fluída funciona num Mac com chip Apple Silicon (M1 ou mais novo) e macOS 15 ou
  posterior.
- Na primeira vez que você usar a voz ou a tradução, o aplicativo precisa baixar os modelos
  correspondentes — só nesse momento é necessária internet. Depois de baixados, tudo funciona sem
  conexão.
- Você escolhe onde esses modelos ficam guardados (pode ser num disco externo, se preferir não
  ocupar espaço no seu Mac). O aplicativo pergunta na primeira vez que precisa saber.

## 1. Abrindo o seu primeiro documento

Pressione **⌘O** (ou o botão "Abrir" que aparece ao iniciar o aplicativo) e escolha qualquer PDF do
seu computador. Enquanto o aplicativo permanece aberto, alternar entre PDF e Imersão preserva a sua
posição. Se você trocar o idioma da interface e escolher **Reiniciar agora**, o documento será
reaberto na mesma página e unidade de leitura. Numa abertura normal, abra o PDF com **⌘O**.

Se o PDF for um documento escaneado (fotos de páginas, sem texto selecionável), a Leitura Fluída
reconhece o texto automaticamente na primeira vez que você o abre. Você verá uma barra de progresso
enquanto isso acontece; pode começar a ler a primeira página assim que ela estiver pronta, sem
esperar o documento inteiro terminar.

A preparação é decidida página por página: o aplicativo mantém o texto digital quando ele é útil e
usa OCR local quando a camada não é confiável. Abra **Detalhes por página** na barra de progresso
para ver o que está pendente, tentar novamente uma página, **Forçar OCR** ou ignorá-la. **Cancelar**
interrompe sem perder as páginas prontas e **Retomar** continua depois.

Quando um PDF precisou de OCR, o aplicativo pergunta se você quer guardar o texto reconhecido dentro
do documento. É opcional: aceitar mantém a aparência e torna o texto pesquisável/selecionável em
outros aplicativos; escolher **Não guardar** deixa o PDF original intacto.

![Visualização PDF da Leitura Fluída com seletor PDF/Imersão, controles de narração, navegação de página e barra de processamento.](docs/images/reader-pdf.png)

## 2. O tour guiado

Na primeira vez que você abrir um documento, aparece um pequeno tour de sete passos que aponta cada
controle real da janela, explicando para que serve. Você pode:

- Clicar em **Próximo** para avançar passo a passo.
- Clicar em **Pular** para fechar o tour imediatamente.
- Marcar **"Não mostrar novamente"** se não quiser vê-lo de novo.

Se mais tarde quiser rever o tour, ele sempre está disponível em **Ajuda → Repetir o tour**.

## 3. Duas formas de ver o mesmo documento

No topo da janela há um seletor **PDF / Imersão** (você também pode alternar entre os dois com
**⌘⇧I**):

- **Modo PDF** mostra o documento exatamente como ele é — com as suas imagens, tabelas e
  diagramação original. Útil quando você precisa ver um gráfico ou uma tabela enquanto lê.
- **Modo Imersão** remove tudo o que não é o próprio texto: números de página, cabeçalhos
  repetidos, rodapés, decorações. Resta só a leitura, numa janela pensada para a concentração. É a
  visualização recomendada se o que você quer é ler sem distrações.

Você pode alternar entre os dois modos a qualquer momento sem perder o seu lugar.

![Detalhe do Modo Imersão com o seletor de visualização e uma unidade de leitura destacada.](docs/images/reader-immersion.png)

### Navegando pelo documento

- O botão da barra lateral (ou **⌘⌥L**) mostra o índice detectado; escolher uma entrada abre a sua
  página. Sem estrutura confiável, o aplicativo informa isso em vez de inventar títulos.
- No Modo PDF, **← / →** e as setas ao lado do número avançam ou voltam páginas.
- Em **⋯ Mais**, gire a página atual para a esquerda (**⌘[**) ou direita (**⌘]**). O aplicativo
  prepara a página novamente para alinhar leitura, OCR e destaque à nova orientação.
- Na Imersão, clique duas vezes numa unidade para começar ali. A rolagem manual suspende o
  acompanhamento; use **Retomar acompanhamento automático** para recuperá-lo.

## 4. Ouvindo enquanto lê

Os controles de reprodução ficam sempre visíveis no topo da janela:

| Botão | O que faz |
|---|---|
| ▶ / ⏸ (ou a barra de espaço) | Reproduz ou pausa a narração |
| ⏮ / ⏭ | Pula para o parágrafo (ou frase) anterior/seguinte |
| Menu **⋯ Mais** → voltar 15s / avançar 15s | Ajusta a posição do áudio sem trocar de parágrafo |
| Menu **⋯ Mais** → velocidade | Escolha entre 0.75×, 1×, 1.25×, 1.5× ou 2× |

Enquanto o texto é lido em voz alta, o aplicativo destaca na tela o trecho sendo narrado, então você
sempre sabe exatamente onde a leitura está.

### Escolhendo uma voz

Na primeira vez que você apertar reproduzir, o aplicativo vai pedir para você escolher e baixar uma
voz (isso pode levar alguns minutos, dependendo da sua conexão). Depois de baixada, ela não será
pedida de novo — fica pronta para todos os seus documentos futuros. Você pode trocar de voz ou de
idioma de leitura a qualquer momento em **⋯ Mais → Voz**.

A folha **Voz** permite escolher a pasta de modelos, revisar procedência/licença, baixar, cancelar ou
tentar novamente e selecionar idioma e voz depois da verificação. Se a narração falhar num trecho,
**⋯ Mais** oferece **Tentar novamente este trecho** e **Ignorar este trecho**; ignorar nunca apaga
texto nem altera o PDF.

## 5. Traduzindo um documento

Em **⋯ Mais → Traduzir**, escolha a pasta de modelos, baixe e verifique o modelo se necessário,
selecione o idioma de destino e pressione **Iniciar tradução**. Download e tradução podem ser
cancelados e repetidos. As direções disponíveis são entre espanhol, inglês e português.

O seletor superior **Texto: Original / Tradução** só aparece depois que a tradução começa ou já
existe. Ele funciona em PDF e Imersão e troca juntos o texto visível e a fonte da narração sem perder
a unidade atual. Antes disso não ocupa espaço na barra. Para ouvir a tradução, instale também uma voz
do idioma de destino.

## 6. Exportando um audiolivro

Se você preferir ouvir fora do aplicativo, vá em **⋯ Mais → Exportar**. A folha informa se exportará
Original ou Tradução e permite escolher nome, idioma, voz e destino. Antes de iniciar, mostra duração
e tamanho estimados, espaço disponível, unidades prontas e conteúdo degradado ou omitido.

O resultado é um único `.m4b`: usa capítulos quando encontra títulos confiáveis e uma faixa contínua
quando não encontra. Exportar pausa a narração ao vivo e pode ser pausado, retomado, cancelado,
reiniciado ou repetido desde o ponto verificado, inclusive depois de reabrir o aplicativo. Ao
terminar, abra o audiolivro ou mostre-o no Finder; o aplicativo nunca sobrescreve outro arquivo nem
altera o PDF.

O audiolivro gerado é o seu arquivo de saída: a licença do programa não se estende a ele. Você pode
usá-lo ou compartilhá-lo, respeitando sempre os direitos do documento de origem.

## 7. Trocando o idioma da interface

Vá em **Ajustes** (**⌘,**) e escolha espanhol, inglês ou português — ou deixe o aplicativo seguir o
idioma do seu sistema. O próprio nome do aplicativo também muda conforme o idioma escolhido:
*Lectura Fluida*, *Fluent Reading* ou *Leitura Fluída*.

Se a troca de idioma exigir reiniciar o aplicativo, você será avisado com clareza e poderá escolher
fazer isso na hora ou mais tarde. Depois de reiniciar, o documento aberto, a página, a unidade de
leitura, as preferências e qualquer narração ativa serão restaurados.

## 8. Outros ajustes úteis

- **Unidade de leitura** (só na Imersão): parágrafo ou frase.
- **Tema** (só na Imersão): papel, sépia ou escuro.
- **Armazenamento**: mostra os dados processados do documento aberto e permite apagá-los sem tocar no
  PDF nem em audiolivros concluídos.
- **Ajuda da Leitura Fluída**: explica uso, limites e privacidade. **Ajuda → Repetir o tour** inicia o
  tour guiado novamente.
- **Sobre a Leitura Fluída** (menu do aplicativo): mostra versão, build, modelos instalados, autoria,
  procedência, licenças e o `NOTICE` incluído.

## Mapa de controles

| Local | Controle | Função e disponibilidade |
|---|---|---|
| Barra superior | Índice | Mostra ou oculta a navegação estrutural. |
| Barra superior | PDF / Imersão | Troca a representação preservando a posição. |
| Barra superior | Anterior · Reproduzir/Pausar · Seguinte | Controla a unidade narrada. |
| Barra superior, PDF | Página anterior · número · seguinte | Navega por páginas. |
| Barra superior, após iniciar tradução | Texto: Original / Tradução | Troca texto e narração nas duas visualizações. |
| Barra superior | ⋯ Mais | Abre documento, troca visualização, gira, gerencia armazenamento, voz, tradução, exportação, unidade, tema, acompanhamento, ±15 s, velocidade e recuperações do estado atual. |
| Menu Leitura | Equivalentes de ⋯ Mais | Dá acesso por teclado e VoiceOver a processamento, voz, tradução, exportação, armazenamento, narração, unidade, tema e acompanhamento. |
| Barra de processamento | Progresso · Detalhes por página · Cancelar/Retomar | Monitora e controla extração, layout e OCR. |
| Folhas | Voz · Tradução · Exportar · Armazenamento · Ajuda | Configura ou inspeciona cada fluxo sem esconder o documento. |
| Ajustes (⌘,) | Idioma da interface | Segue o sistema ou fixa português, espanhol ou inglês. |

## Atalhos de teclado

| Atalho | Ação |
|---|---|
| ⌘O | Abrir um documento |
| ⌘⇧I | Alternar entre Modo PDF e Modo Imersão |
| Espaço | Reproduzir / pausar a narração |
| ← / → | Página anterior / seguinte (no Modo PDF) |
| ⌥← / ⌥→ | Voltar / avançar 15 segundos |
| ⌘⌥L | Mostrar ou ocultar o índice de navegação |
| ⌘[ / ⌘] | Girar a página atual para a esquerda / direita |
| ⌘⇧V | Abrir Voz |
| ⌘⌥T | Abrir Tradução |
| ⌘⇧E | Abrir Exportar áudio |
| ⌘⌥S | Abrir Armazenamento |
| ⌘⇧R / ⌘⇧T | Retomar / tentar novamente o processamento |
| ⌘⇧F | Retomar acompanhamento automático (Imersão) |
| ⌘, | Abrir Ajustes |
| ⌘? | Abrir a ajuda |
| Esc | Cancelar o processamento em andamento |

## Perguntas frequentes

**O aplicativo envia o meu documento para a internet?**
Não, nunca. Todo o reconhecimento de texto, a voz e a tradução acontecem dentro do seu próprio
computador. A única conexão usada é para baixar os modelos na primeira vez.

**Abri um documento escaneado e ele está demorando para ficar pronto. É normal?**
Sim — se o PDF não tem texto selecionável, o aplicativo precisa reconhecê-lo primeiro (OCR). Você
pode começar a ler a primeira página assim que ela aparece; o resto continua sendo processado em
segundo plano.

**A narração parou com um aviso de erro. O que eu faço?**
O menu **⋯ Mais** oferece um botão para tentar novamente aquela parte, ou para pulá-la e seguir em
frente.

**Posso usar o aplicativo sem mouse, só com o teclado?**
Sim — todos os controles principais têm um atalho de teclado (veja a tabela acima), e o aplicativo
funciona com o VoiceOver.

**Onde ficam guardados os modelos de voz e tradução?**
Onde você escolher — pode ser o seu Mac ou um disco externo. O aplicativo nunca impõe uma pasta
fixa.

**Escolhi uma pasta e aparece “Motor de voz não encontrado”. O que faço?**
Abra **⋯ Mais → Voz → Escolher pasta de modelos…** e selecione a pasta onde o aplicativo baixou o
modelo verificado. Escolher uma pasta com apenas pesos soltos ou mover só parte do modelo quebra o
conjunto; nesse caso, baixe-o novamente na mesma folha.
