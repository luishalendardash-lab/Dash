# O que subir para ficar em dia

Versão do Worker no fim disto: **v44-manychat-fluxo**

Confira em `https://dash.luishalendardash.workers.dev/health` — se aparecer
`"versao": "v44-manychat-fluxo"`, o backend está atualizado.

---

## 1. SQLs no Supabase

Rode na ordem, no SQL Editor. Cada um é independente e pode rodar duas
vezes sem estragar nada.

| # | Arquivo | O que faz |
|---|---------|-----------|
| 48 | `48_separar_telas.sql` | separa Faturamento (negócio) de Vendas (lançamento) |
| 49 | `49_painel_lancamento.sql` | painel da Home com todos os indicadores |
| 50 | `50_serie_lancamento.sql` | o gráfico segue o período do lançamento |
| 51 | `51_campanhas_periodo.sql` | escolher campanhas do Meta por período |
| 52 | `52_import_campanhas_csv.sql` | investimento pelo CSV de campanhas |
| 53 | `53_apagar_lancamento.sql` | apagar lançamento criado por engano |
| 54 | `54_manychat_direto.sql` | ManyChat sem o n8n |
| 55 | `55_manychat_fluxo.sql` | disparo do fluxo e criação de tag |

Se algum der erro, pare e me mande a mensagem. Não pule.

---

## 2. Backend (Cloudflare Worker)

Substitua `index.ts` pelo do pacote e faça deploy.

### Variáveis novas

Em **Settings → Variables and Secrets**:

| Nome | Tipo | Valor |
|------|------|-------|
| `MANYCHAT_TOKEN` | Secret | o token do ManyChat |
| `MANYCHAT_FLOW` | Text | `content20260822143758_588317` |

O token antigo apareceu num arquivo compartilhado. Gere um novo em
ManyChat → Settings → API antes de colar aqui.

---

## 3. Frontend (Cloudflare Pages)

Substitua `index.html` pelo do pacote.

---

## 4. Conferir depois de subir

**Home** — deve mostrar o painel do lançamento com receita, investimento,
lucro e a tabela geral × engenheiro.

**Faturamento** (menu Negócio) — os cartões por plataforma que antes
ficavam na Home.

**Vendas** — o botão "⚙️ Carrinho e produtos" no topo.

**Ajustes** — o botão "Apagar este lançamento" ao lado de Salvar.

**Anúncios** — o botão "💸 Buscar investimento no Meta".

Se alguma tela ficar em branco ou mostrar erro, me diga qual.

---

## 5. Ativar o ManyChat direto

Em **Integrações → ManyChat (direto)**:

```
Token da API      →  vazio (usa MANYCHAT_TOKEN)
Fluxo ao entrar   →  vazio (usa MANYCHAT_FLOW)
Tag ao entrar     →  vazio (a tag vem do fluxo 1)
Campo lançamento  →  vazio, ou o nome de um campo personalizado
```

Marque como **ativa**. Isso desliga o repasse pelo n8n automaticamente.

Teste com um número que **nunca conversou** com o seu ManyChat. Com um
número que já falou, a janela de 24 horas está aberta e o teste passa
mesmo se o template estiver errado.

---

## 6. O que ainda está pendente do combinado

- [ ] Trocar `WEBHOOK_SECRET` e `DEBUG_TOKEN` (o valor `dashperito1234`
      apareceu na conversa)
- [ ] Investimento do Nov/25 e leads daquele lançamento
- [ ] Segunda conta de anúncio, se ela também rodou nesses lançamentos
- [ ] Configurar carrinho e produtos de cada lançamento em
      Vendas → Carrinho e produtos
