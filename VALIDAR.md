# Roteiro de validação — Dash de Lançamento

Siga na ordem. Cada etapa tem **o que fazer**, **o que precisa acontecer** e
**onde olhar se der errado**.

Reserve uma hora. Fazer isso agora custa muito menos do que descobrir no dia
da captação.

---

## 0. O básico está no ar?

**Faça:** abra `SEU_WORKER/health` no navegador.

**Precisa aparecer:**
- `"versao": "v27-custos"` — se for outra, o deploy não pegou
- `supabase: "ok"`
- `meta_token: "configurado"`
- `hotmart_hottok` — só importa se o cliente vende pela Hotmart

**Se a versão estiver velha:** Cloudflare → Workers → seu Worker → Deployments.
Costuma ser cache de build; um novo commit resolve.

**Depois:** entre na dash e faça login. Se o login falhar, confira se o usuário
existe em Supabase → Authentication → Users, com *Auto Confirm* marcado.

---

## 1. Ajustes — o painel de estado

**Faça:** abra a aba **Ajustes** e olhe o bloco "Estado da operação".

**Precisa aparecer:** cinco itens. Os que estiverem em amarelo dizem o que
falta e por quê.

Resolva os amarelos antes de continuar. Os mais comuns nesta fase:
- *Quiz vazio* → aba Quiz
- *Falta o link do grupo* → Ajustes, campo "Link do grupo"
- *Nenhuma conta do Meta* → Ajustes, campo "Contas de anúncio"

**Aproveite para conferir:** metas de leads e investimento, e os descontos
em "Imposto e taxas". Se o cliente tem coprodução, cadastre agora — senão o
líquido vai aparecer maior do que é.

---

## 2. Integrações — está tudo recebendo?

**Faça:** abra a aba **Integrações** e olhe a bolinha de cada card.

| Cor | O que significa |
|---|---|
| 🟢 Verde | recebeu dados nas últimas 72h |
| 🟡 Amarela | ligada, mas sem dado recente |
| 🔴 Vermelha | teve falha de processamento |
| ⚪ Cinza | desligada |

Nesta fase, amarelo é esperado — ainda não houve movimento real.

**Confira as que precisam de credencial:**
- Hotmart → o Hottok está salvo? (mostra `••••` + final)
- SellFlux → a URL do formulário está salva?
- ManyChat → o webhook está salvo?
- TMB → os dois webhooks foram cadastrados **em cada produto**?

---

## 3. O caminho do lead — o teste principal

Esta é a etapa que vale por todas as outras.

**Faça:** aba Quiz → botão **Testar página**. Abre uma prévia do que o lead vê.

Preencha com dados reais seus: seu nome, seu e-mail, seu WhatsApp.
Responda o quiz até o fim.

**Precisa acontecer, nesta ordem:**

1. O formulário aceita e troca para o quiz **sem recarregar a página**
2. As perguntas aparecem uma a uma
3. Se houver pergunta condicional, ela só aparece quando a condição bate
4. No fim, redireciona para o grupo do WhatsApp

**Agora confira nas quatro pontas:**

**Na dash** → aba Leads. Você deve estar lá, com:
- telefone no formato `+5553999887766`
- etapa avançada (não "frio")
- clicando no seu nome: a jornada com captura e quiz

**No SellFlux** → o contato entrou? Com telefone certo? **Entrou no fluxo de
e-mail** ou só ficou na lista? Essa é a pergunta que mais importa aqui.

**No WhatsApp** → chegou a mensagem do ManyChat?

**No grupo** → você entrou?

**Se o lead não chegou no SellFlux:** no SQL Editor do Supabase:

```sql
select recebido_em, fonte, erro
from dash.webhooks_raw
where fonte like 'saida_%'
order by recebido_em desc limit 5;
```

Linha com `saida_sellflux_falhou` mostra o erro. Vazio significa que o
SellFlux aceitou — se mesmo assim o contato não está lá, é formato de campo.

---

## 4. Meta Ads — os anúncios aparecem?

**Pré-requisito:** pelo menos uma campanha cujo nome **começa** com o código
do lançamento (ex: `L2610 - Captação - Vídeo 1`).

**Faça:** abra `SEU_WORKER/sync/meta?token=SEU_DEBUG_TOKEN&lancamento=SEU_SLUG&dias=30`

**Precisa retornar:** `"ok": true` com a contagem de entidades e insights.

**Depois:** aba **Anúncios**. As campanhas devem estar listadas com gasto,
impressões e cliques.

**Se vier vazio:**
- O nome da campanha começa mesmo com o código? Maiúsculas contam
- As duas contas estão em Ajustes → Contas de anúncio?
- O `META_TOKEN` tem permissão `ads_read` nas duas contas?

**Se der erro 190:** o token expirou. Gere outro pelo usuário do sistema, sem
prazo de expiração.

---

## 5. Uma venda de teste

**Se for Hotmart:** o painel dela tem botão de teste no cadastro do webhook.

**Se for outra:** faça uma compra real de R$ 1 numa oferta de teste, ou peça
para a plataforma disparar um evento.

**Precisa acontecer:** a venda aparece na aba **Vendas** em segundos.

**Confira:**
- valor certo (na TMB: o valor total do contrato, não a parcela)
- produto preenchido
- se você comprou com o mesmo e-mail do lead de teste, a venda deve estar
  **atribuída** — aparece o anúncio na coluna "Veio de"
- se o link tinha `sck`, ele aparece na coluna SCK

**Se a venda não chegou:**

```sql
select recebido_em, fonte, processado, erro
from dash.webhooks_raw
order by recebido_em desc limit 10;
```

- Não tem linha nenhuma → o webhook não está chegando. Confira a URL na
  plataforma, e se o segredo bate
- Tem linha com `processado = false` → chegou mas o processamento falhou; o
  `erro` diz o motivo
- Tem linha `hotmart_hottok_invalido` → o Hottok cadastrado está diferente do
  que a Hotmart enviou

---

## 6. Os números batem?

**Home:** receita de todas as plataformas, no período escolhido.
**Vendas:** só o lançamento selecionado.

Os dois **não vão bater**, e está certo. A Home é o faturamento do mês; a
tela de Vendas é o resultado do lançamento.

**Confira na Home:**
- a receita bruta bate com a soma das plataformas?
- embaixo da líquida aparece a linha dos descontos?
- o filtro de produto muda os números?

**Confira em Vendas:**
- a taxa de atribuição faz sentido? Se muitas vendas estão "sem lead", ou o
  cruzamento não achou (e-mail diferente), ou o tráfego não veio da captação
- o gráfico por dia mostra as vendas nos dias certos?

---

## 7. Aulas

**Faça:** aba Aulas → ＋ Aula. Cadastre as três aulas do lançamento com
número, título e data.

Deixe os números vazios — você preenche depois de cada aula.

**Lembre:** o pico de simultâneos precisa ser anotado **durante** a live.
O YouTube não guarda esse número depois que a transmissão acaba.

---

## 8. Antes de virar a chave

**Trocar os dois segredos.** `WEBHOOK_SECRET` e `DEBUG_TOKEN` estão com
valores fracos. Gere strings aleatórias no Worker.

⚠️ Ao trocar o `WEBHOOK_SECRET`, **todas as URLs de webhook mudam**. Você
precisa atualizar em cada plataforma: Hotmart, TMB (dois por produto),
SellFlux, SendFlow, ManyChat. Faça isso num momento sem movimento.

**Zerar os dados de teste.** Ajustes → Limpar dados de teste → escreva
`ZERAR`. Apaga leads e vendas, mantém quiz, integrações e configurações.

**Conferir o link do grupo.** Se aparecer o aviso de link repetido na aba
Quiz, o grupo é do lançamento anterior. Troque antes de publicar.

---

## Onde olhar quando algo estranho acontecer

**Ver os últimos webhooks recebidos:**
```
SEU_WORKER/debug/ultimos?token=SEU_DEBUG_TOKEN
```

**Reprocessar o que falhou** (depois de corrigir a causa):
```
POST SEU_WORKER/debug/reprocessar?token=SEU_DEBUG_TOKEN
```

**Vendas sem lead:** botão Reconciliar, na aba Vendas. Tenta ligar de novo
pelo telefone. Roda sozinho de hora em hora também.

**Erros das integrações:** aba Ajustes, tabela "Últimos erros de webhook".

---

## O que a dash não faz

Vale ter claro para não procurar o que não existe:

- Não acompanha pagamento de parcela ao longo dos meses (só faturado e pago)
- Não puxa retenção do YouTube automaticamente (é lançado à mão)
- Não envia e-mail nem WhatsApp — ela repassa para SellFlux e ManyChat
- Não substitui o painel da plataforma para conferência fiscal
