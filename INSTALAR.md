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

Não existe arquivo 19 — ele foi substituído pelo 20.

**Se você já rodou até o 14 antes**, precisa rodar do 15 ao 20 agora.

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
"versao": "v21-tmb-simples"
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

## O que ainda não existe

- Tela de **Aulas / YouTube**
- Tela de **Ajustes** (imposto, metas e plataformas ainda são editados por SQL)
- Limpeza final dos dados de teste
