# UTMs do Meta Ads — o que colar

Cole isto no campo **Parâmetros de URL** do anúncio, em uma linha só:

```
utm_source=facebook&utm_medium=paid&utm_campaign={{campaign.name}}&utm_content={{ad.name}}&utm_term={{adset.name}}&cid={{campaign.id}}&aid={{adset.id}}&adid={{ad.id}}
```

---

## Por que assim

A dash usa **dois caminhos** para saber de onde o lead veio, e os dois
importam:

**Pelo ID** (`cid`, `aid`, `adid`) — é exato e nunca muda. Mesmo que você
renomeie o anúncio depois, o histórico continua batendo.

**Pelo nome** (`utm_campaign`, `utm_content`) — é o que aparece nas telas,
e serve de reserva quando o ID não vem.

O erro que vimos nos lançamentos anteriores foi ter só os nomes, e com o
ID do conjunto no lugar do ID do anúncio. Por isso o gasto não casava com
o criativo.

---

## O que cada um vira na dash

| Parâmetro | Valor | Onde aparece |
|---|---|---|
| `utm_source` | `facebook` | origem do lead |
| `utm_medium` | `paid` | separa pago de orgânico |
| `utm_campaign` | `{{campaign.name}}` | nome da campanha |
| `utm_content` | `{{ad.name}}` | **nome do criativo** — a coluna principal da tela de Anúncios |
| `utm_term` | `{{adset.name}}` | nome do conjunto |
| `cid` | `{{campaign.id}}` | id da campanha |
| `aid` | `{{adset.id}}` | id do conjunto |
| `adid` | `{{ad.id}}` | **id do anúncio** — é o que casa o gasto com o lead |

A ordem não altera nada tecnicamente. Mantenha esta para ficar fácil de
conferir a olho.

---

## Cuidados

**Não troque `{{ad.id}}` por `{{adset.id}}`.** Foi exatamente essa inversão
que quebrou a atribuição nos lançamentos passados: o gasto de cada criativo
não encontrava os leads dele.

**Não use espaço nem quebra de linha** no campo. O Meta aceita, mas alguns
navegadores cortam a URL no espaço.

**Se a landing já tiver `?`** em outro parâmetro, o Meta resolve sozinho —
não acrescente `&` no começo.

**Confira depois de publicar.** Clique no próprio anúncio e olhe a barra de
endereços: as chaves `{{ }}` devem ter virado valores. Se aparecer
`{{ad.name}}` literal na URL, o Meta não substituiu, e a dash vai receber
esse texto como se fosse o nome do criativo.

---

## Conferir se está funcionando

Depois de alguns leads entrarem:

```sql
select utm_source, utm_content, meta_ad_id, count(*)
from dash.inscricoes
where capturado_em > now() - interval '2 days'
group by 1, 2, 3
order by 4 desc
limit 10;
```

O que você quer ver:

- `meta_ad_id` com número puro, tipo `120230028415270179`
- `utm_content` com o nome do criativo, tipo `ADS01` ou `[ADS10]`

Se `meta_ad_id` vier com texto entre colchetes, é nome no lugar do id — e
aí o parâmetro está trocado.

---

## Nome da campanha

A dash descobre a qual lançamento o gasto pertence pela **data no nome da
campanha**. Mantenha o padrão que você já usa:

```
[10.01.26][CAPTAÇÃO][LP03][ABO][FRIO]
```

A palavra `CAPTAÇÃO` também importa: é ela que separa o investimento que
traz lead do que é remarketing ou vendas.
