# Dash de Lançamento — Backend

Worker único do Cloudflare. Recebe os leads e serve a dash.

## Estrutura

```
index.ts          <- o Worker (precisa ficar na RAIZ)
wrangler.jsonc    <- configuração (precisa ficar na RAIZ)
sql/              <- migrações do Supabase, na ordem numérica
```

`index.ts` e `wrangler.jsonc` ficam na raiz de propósito: o wrangler
procura o `wrangler.jsonc` na raiz do diretório de build e resolve o
`main` a partir dali. Colocar em subpasta exige configurar o
"Root directory" no painel do Cloudflare.

A pasta `sql/` não entra no deploy — é só histórico versionado.

## Configuração no Cloudflare

Workers & Pages > dash > Settings > Variables and Secrets

### Secrets
| Nome | Valor |
|---|---|
| `SUPABASE_URL` | https://xxxx.supabase.co |
| `SUPABASE_SERVICE_KEY` | service_role (nunca no front) |
| `SUPABASE_ANON_KEY` | anon / public |
| `WEBHOOK_SECRET` | segredo que vai na URL dos webhooks |
| `DEBUG_TOKEN` | segredo das rotas /debug |
| `SELLFLUX_ENDPOINT` | opcional — URL de POST do SellFlux |
| `MANYCHAT_WEBHOOK` | opcional — webhook que repassa ao ManyChat |

### Variáveis (tipo Text)
| Nome | Valor |
|---|---|
| `LANCAMENTO_PADRAO` | lanc-2026-09 |
| `ORIGENS_PERMITIDAS` | https://dashperito.pages.dev |

**Sem barra no final em `ORIGENS_PERMITIDAS`.** O navegador manda a
origem sem barra; com barra a comparação nunca bate e o login falha.

### Build configuration
| Campo | Valor |
|---|---|
| Root directory | (vazio) |
| Deploy command | `npx wrangler deploy` |

## Rotas

### Entrada de dados
- `POST /captura` — formulário próprio, grava e repassa
- `POST /w/:fonte/:secret` — webhook (hotmart, sellflux, manychat, sendflow, quiz)
- `GET /r/grupo/:secret?i=<inscricao_id>&l=<slug>` — redirect rastreado

### Dash
- `POST /api/login` — { email, senha }
- `POST /api/refresh` — { refresh }
- `GET /api/lancamentos`
- `GET /api/home?lancamento=&periodo=&dias=`
- `GET /api/leads?lancamento=&etapa=&busca=&pagina=`
- `GET /api/lead/:id`

### Diagnóstico
- `GET /health` — mostra quais variáveis chegaram
- `GET /debug/ultimos?token=&fonte=` — payloads crus recebidos
- `POST /debug/reprocessar?token=` — reprocessa o que falhou

## Ordem das migrações

Rodar no SQL Editor do Supabase, na ordem:

1. `01_schema_dash_lancamento.sql` — tabelas
2. `02_rpc_ingest.sql` — RPCs de entrada
3. `03_fix_telefone.sql` — normalização de telefone
4. `04_fix_dedupe.sql` — trava de lead duplicado
5. `05_etapa_lead.sql` — etapa calculada
6. `06_dash_home.sql` — plataformas, imposto e RPCs da home

Também é preciso, uma vez:
- Settings > API > Exposed schemas: adicionar `dash`
- Authentication > Users: criar o usuário com "Auto Confirm"
- Authentication > Providers > Email: desligar "Enable sign ups"

## Confirmar que o deploy pegou

`GET /health` deve responder com:

```
"anon_key": true,
"versao": "unificada-v2",
"manychat": "nao configurado"
```

Se esses campos não aparecerem, o Worker no ar ainda é uma versão antiga.
