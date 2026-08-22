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
seu computador. O aplicativo lembra automaticamente em que página e posição você parou, então na
próxima vez que abrir o mesmo documento você retoma exatamente de onde ficou.

Se o PDF for um documento escaneado (fotos de páginas, sem texto selecionável), a Leitura Fluída
reconhece o texto automaticamente na primeira vez que você o abre. Você verá uma barra de progresso
enquanto isso acontece; pode começar a ler a primeira página assim que ela estiver pronta, sem
esperar o documento inteiro terminar.

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

## 5. Traduzindo um documento

Em **⋯ Mais → Traduzir**, você pode ativar a tradução do seu documento (hoje, entre espanhol,
inglês e português). Assim como com a voz, o modelo de tradução é baixado na primeira vez; depois
disso funciona offline.

Uma vez ativada, o menu **⋯ Mais** mostra um seletor **Original / Tradução** para escolher qual você
ouve ou lê. Você pode alternar entre os dois a qualquer momento sem perder o seu lugar — a Leitura
Fluída mantém o texto original e o traduzido sincronizados entre si.

## 6. Exportando um audiolivro

Se você preferir ouvir o documento fora do aplicativo (no carro, caminhando, sem olhar para uma
tela), vá em **⋯ Mais → Exportar**. A Leitura Fluída gera um arquivo de áudio (`.m4b`) com
capítulos, que você pode reproduzir em qualquer player compatível com audiolivros. A exportação pode
ser pausada e retomada, e se você cancelar no meio do caminho nada fica pela metade: o documento
original nunca é afetado.

## 7. Trocando o idioma da interface

Vá em **Ajustes** (**⌘,**) e escolha espanhol, inglês ou português — ou deixe o aplicativo seguir o
idioma do seu sistema. O próprio nome do aplicativo também muda conforme o idioma escolhido:
*Lectura Fluida*, *Fluent Reading* ou *Leitura Fluída*.

Se a troca de idioma exigir reiniciar o aplicativo, você será avisado com clareza e poderá escolher
fazer isso na hora ou mais tarde, sem perder as suas preferências salvas.

## 8. Outros ajustes úteis

Todos estes ficam no menu **⋯ Mais**, no canto superior direito da janela:

- **Unidade de acompanhamento**: escolha se a leitura avança parágrafo por parágrafo ou frase por
  frase.
- **Tema do Modo Imersão**: papel (claro), sépia ou escuro — para uma leitura confortável conforme
  a luz do ambiente.
- **Armazenamento**: consulte ou libere o espaço usado pelos documentos já processados.

## Atalhos de teclado

| Atalho | Ação |
|---|---|
| ⌘O | Abrir um documento |
| ⌘⇧I | Alternar entre Modo PDF e Modo Imersão |
| Espaço | Reproduzir / pausar a narração |
| ← / → | Página anterior / seguinte (no Modo PDF) |
| ⌘⌥L | Mostrar ou ocultar o índice de navegação |
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
