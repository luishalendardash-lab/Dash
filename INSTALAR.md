# Dash de Lançamento — o que subir

Guia do estado atual. Se você está retomando depois de um tempo, comece aqui.

---

## 1. Banco (Supabase)

SQL Editor → cole e rode **um arquivo por vez, na ordem**.
Pode rodar de novo sem medo: todos são feitos para repetir sem quebrar nada.

| # | Arquivo | O que faz |
|---|---|---|
| 01 | `01_schema_dash_lancamento.sql` | tabelas |
| 02 | `02_rpc_ingest.sql` | entradas de dados |
| 03 | `03_fix_telefone.sql` | normaliza telefone |
| 04 | `04_fix_dedupe.sql` | impede lead duplicado |
| 05 | `05_etapa_lead.sql` | etapa calculada |
| 06 | `06_dash_home.sql` | plataformas, imposto, home |
| 07 | `07_meta_ads.sql` | campanhas e gastos |
| 08 | `08_codigo_lancamento.sql` | código do lançamento |
| 09 | `09_codigo_editavel.sql` | código editável |
| 10 | `10_purgar_ads.sql` | limpa anúncio fora do código |
| 11 | `11_tela_anuncios.sql` | tela de anúncios |
| 12 | `12_quiz.sql` | quiz |
| 13 | `13_quiz_fluxo.sql` | abertura, pergunta aberta, condicional |
| 14 | `14_vendas.sql` | tela de vendas |
| 15 | `15_integracoes.sql` | tabela de integrações |
| 16 | `16_catalogo_integracoes.sql` | Hotmart, Kiwify, HeroSpark, Guru |
| 17 | `17_tmb.sql` | TMB |
| 18 | `18_tmb_webhook.sql` | TMB por webhook |
| 20 | `20_tmb_simples.sql` | TMB: faturado e pago |
| 21 | `21_aulas.sql` | diário de bordo das aulas |
| 22 | `22_vendas_sck.sql` | origem do link e série diária |
| 23 | `23_produtos.sql` | filtro e quebra por produto |
| 24 | `24_correcoes.sql` | copiar quiz, CPL sem investimento |
| 25 | `25_conserta_home.sql` | conserta a Home |
| 26 | `26_ajustes.sql` | tela de ajustes |
| 27 | `27_custos.sql` | impostos e custos configuráveis |
| 28 | `28_manychat_n8n.sql` | ManyChat via n8n |
| 29 | `29_webhook_lancamento.sql` | webhook por lançamento (SendFlow) |
| 30 | `30_importar.sql` | importar histórico e os 6 lançamentos FPEE |
| 31 | `31_data_webhook.sql` | aceita data brasileira nos webhooks |
| 32 | `32_tags_recorrencia.sql` | importar por tags e análise de recorrência |
| 33 | `33_tags_padrao.sql` | importar por padrão de tag |
| 34 | `34_vendas_por_data.sql` | vendas com lançamento pela data |
| 35 | `35_completar_utm.sql` | completar UTM de leads já importados |
| 36 | `36_planilhas_captura.sql` | planilhas de captura com anúncio e quiz |
| 37 | `37_desempenho_criativo.sql` | CPL, CPL engenheiro e CPA por criativo |
| 38 | `38_ads_historico.sql` | investimento de lançamentos antigos pelo ID |

Não existe arquivo 19 — foi substituído pelo 20.

Os 26 arquivos foram executados numa instalação limpa antes desta entrega.

### Uma vez só, no painel do Supabase

- Settings → API → **Exposed schemas**: adicionar `dash`
- Authentication → Users → **Add user** (marque *Auto Confirm*) — é o login da dash
- Authentication → Providers → Email → **desligar** *Enable sign ups*

---

## 2. Backend (Worker)

Repositório do Worker, na raiz: `index.ts` e `wrangler.jsonc`.
A pasta `sql/` fica junto só como histórico — não entra no deploy.

### Secrets (Settings → Variables and Secrets, tipo **Secret**)

| Nome | Onde pegar |
|---|---|
| `SUPABASE_URL` | Supabase → Settings → API |
| `SUPABASE_SERVICE_KEY` | a `service_role` |
| `SUPABASE_ANON_KEY` | a `anon / public` |
| `WEBHOOK_SECRET` | string aleatória sua |
| `DEBUG_TOKEN` | outra string aleatória |
| `META_TOKEN` | token do usuário do sistema do Business Manager |

Opcionais (dá para configurar pela tela de Integrações em vez destes):
`HOTMART_HOTTOK`, `SELLFLUX_ENDPOINT`, `MANYCHAT_WEBHOOK`, `TMB_TOKEN`

### Variáveis (tipo **Text**)

| Nome | Valor |
|---|---|
| `LANCAMENTO_PADRAO` | `lanc-2026-09` |
| `META_API_VERSAO` | `v25.0` |

### Build

| Campo | Valor |
|---|---|
| Root directory | *(vazio)* |
| Build command | *(vazio)* |
| Deploy command | `npx wrangler deploy` |

**Não deixe `package.json` nem `tsconfig.json` no repositório** — eles fazem o build falhar sem motivo.

### Confirmar que subiu

Abra `/health`. Precisa aparecer:

```
"versao": "v43-manychat-direto"
```

Se a versão não mudou, o deploy não pegou. Verifique em Deployments; muitas vezes é o cache de build.

---

## 3. Frontend (Cloudflare Pages)

| Arquivo | O que é |
|---|---|
| `index.html` | a dash |
| `quiz.html` | quiz avulso (o widget da LP não depende dele) |

Configuração do Pages: build command vazio, output `/`, root vazio.

No topo do script de cada arquivo há **uma linha** para conferir:

```js
var API = 'https://dash.luishalendardash.workers.dev';
```

---

## 4. Landing page

Nada de arquivo aqui. Na aba **Quiz** da dash, copie as duas linhas do painel
"Código para a landing page" e cole num widget HTML do Elementor, no lugar do
formulário atual.

---

## Ordem de teste depois de subir

1. `/health` → confere a versão e se as chaves aparecem
2. Login na dash
3. Aba **Integrações** → deve listar as plataformas
4. Aba **Quiz** → monta o quiz, cola o link do grupo, clica em "Testar página"
5. Preenche o formulário de teste → o lead aparece na aba **Leads**
6. `/sync/meta?token=SEU_DEBUG_TOKEN&lancamento=lanc-2026-09&dias=30` → aba **Anúncios**

---

## Antes de entrar em operação

Na aba **Ajustes**, o painel "Estado da operação" mostra o que falta.
Além dele, três coisas:

**1. Trocar os dois segredos.** `WEBHOOK_SECRET` e `DEBUG_TOKEN` estão com
valores fracos e apareceram em conversa. Gere strings aleatórias novas no
Worker e **atualize as URLs nas plataformas** — elas contêm o segredo.

**2. Zerar os dados de teste.** Ajustes → Limpar dados de teste.
Apaga leads e vendas, mantém quiz, integrações e configurações.

**3. Teste ponta a ponta.** Um lead pelo formulário real, passando pelo
quiz até o grupo, conferindo se chegou nas três pontas: dash, SellFlux e
ManyChat.

## Rotina de cada lançamento

1. Criar o lançamento (gera o código, ex: `L2610`)
2. Ajustes → metas, link do grupo novo, contas do Meta
3. Quiz → copiar do anterior e revisar
4. Integrações → SendFlow: criar conexão nova com a URL do lançamento
4. Copiar as duas linhas e trocar o formulário na LP
5. Colocar o código no início do nome das campanhas, nas duas contas
6. Cadastrar as aulas

As integrações **não** precisam ser refeitas: valem para sempre.
