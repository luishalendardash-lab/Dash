-- =====================================================================
-- 20 — TMB SIMPLIFICADA
--
-- Substitui o controle de parcelas do arquivo 19. Dois números bastam:
--   faturamento = valor total contratado
--   pago        = quanto o aluno já pagou
--
-- Sem tabela de parcelas, sem vencimento, sem inadimplência. A dash
-- acompanha lançamento, não cobrança.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. FORA O QUE SOBROU DO CONTROLE DE PARCELAS
-- ---------------------------------------------------------------------
drop function if exists public.ingest_parcelas(jsonb);
drop function if exists public.religar_parcelas(jsonb);
drop table if exists dash.parcelas;

alter table dash.vendas
  drop column if exists valor_contratado,
  drop column if exists parcelas_pagas;

-- quanto o comprador já pagou. Em plataforma à vista, igual ao bruto.
-- (o arquivo 19 foi descartado, então a coluna pode não existir ainda)
alter table dash.vendas
  add column if not exists valor_recebido numeric(14,2) not null default 0,
  add column if not exists parcelas_total int;

comment on column dash.vendas.valor_recebido is
  'Quanto o comprador ja pagou. Em plataforma a vista e igual ao valor_bruto.';

-- ---------------------------------------------------------------------
-- 2. ATUALIZAR O PAGO
--    O webhook financeiro da TMB avisa parcela a parcela. Em vez de
--    guardar cada uma, só somamos no total pago do pedido.
--    p: { pedido_id, valor, status }
-- ---------------------------------------------------------------------
create or replace function public.registrar_pagamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_id uuid; v_pago numeric; v_bruto numeric;
begin
  select id, valor_recebido, valor_bruto into v_id, v_pago, v_bruto
  from dash.vendas
  where plataforma = 'tmb' and transacao_id = p->>'pedido_id';

  if v_id is null then
    return jsonb_build_object('ok', false, 'erro', 'pedido ainda nao registrado');
  end if;

  -- só conta o que foi efetivamente recebido
  if lower(coalesce(p->>'status','')) not like '%recebid%' then
    return jsonb_build_object('ok', true, 'ignorado', true);
  end if;

  -- guarda cada parcela paga no raw para não somar duas vezes o mesmo aviso
  if (v_bruto > 0) and (p ? 'parcela_id') and
     (select raw->'_parcelas_pagas' ? (p->>'parcela_id') from dash.vendas where id = v_id)
  then
    return jsonb_build_object('ok', true, 'ja_contabilizada', true);
  end if;

  update dash.vendas set
    valor_recebido = least(valor_bruto, coalesce(valor_recebido,0) + coalesce((p->>'valor')::numeric, 0)),
    raw = jsonb_set(
      coalesce(raw,'{}'::jsonb), '{_parcelas_pagas}',
      coalesce(raw->'_parcelas_pagas','{}'::jsonb) ||
      jsonb_build_object(coalesce(p->>'parcela_id','x'), true)
    )
  where id = v_id
  returning valor_recebido into v_pago;

  return jsonb_build_object('ok', true, 'pago', v_pago, 'de', v_bruto);
end $$;

-- lote, do jeito que a TMB manda
create or replace function public.ingest_pagamentos(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_item jsonb; v_d jsonb; v_qtd int := 0;
begin
  for v_item in select * from jsonb_array_elements(
    case when jsonb_typeof(p->'itens') = 'array' then p->'itens' else '[]'::jsonb end
  )
  loop
    v_d := coalesce(v_item->'dados', v_item);
    perform public.registrar_pagamento(jsonb_build_object(
      'pedido_id', v_d->>'pedido_id',
      'parcela_id', v_d->>'parcela_id',
      'valor', v_d->>'repasse',
      'status', v_d->>'status_pagamento'
    ));
    v_qtd := v_qtd + 1;
  end loop;
  return jsonb_build_object('ok', true, 'avisos', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 3. RECEITA — faturamento e pago, sem mais nada
-- ---------------------------------------------------------------------
create or replace function public.dash_receita(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_inicio timestamptz; v_fim timestamptz; v_imposto numeric;
  v_linhas jsonb; v_bruto numeric := 0; v_liquido numeric := 0;
  v_itens int := 0; v_pago numeric := 0;
begin
  v_inicio := coalesce((p->>'inicio')::timestamptz, date_trunc('month', now()));
  v_fim    := coalesce((p->>'fim')::timestamptz, now() + interval '1 day');

  select coalesce((valor)::text::numeric, 0) into v_imposto
  from dash.config where chave = 'imposto_percentual';
  v_imposto := coalesce(v_imposto, 0);

  with base as (
    select
      v.plataforma,
      count(*) as itens,
      sum(v.valor_bruto) as bruto,
      sum(
        case when v.valor_liquido > 0 then v.valor_liquido
             else greatest(0, v.valor_bruto
                  - (v.valor_bruto * coalesce(pl.taxa_percentual,0) / 100)
                  - coalesce(pl.taxa_fixa,0))
        end
      ) as liquido_plataforma,
      -- parcelado tem valor_recebido próprio; à vista, pago = faturado
      sum(case when v.plataforma = 'tmb'
               then coalesce(v.valor_recebido, 0)
               else v.valor_bruto end) as pago
    from dash.vendas v
    left join dash.plataformas pl on pl.slug = v.plataforma
    where v.status = 'aprovada'
      and v.ocorreu_em >= v_inicio and v.ocorreu_em < v_fim
    group by v.plataforma
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'slug', b.plataforma,
      'nome', coalesce(pl.nome, initcap(b.plataforma)),
      'inicial', coalesce(pl.inicial, upper(left(b.plataforma,1))),
      'cor', coalesce(pl.cor, '#666666'),
      'itens', b.itens,
      'bruto', round(b.bruto, 2),
      'liquido', round(b.liquido_plataforma * (1 - v_imposto/100), 2),
      'pago', round(b.pago, 2),
      'parcelado', b.plataforma = 'tmb'
    ) order by b.bruto desc), '[]'::jsonb),
    coalesce(sum(b.bruto), 0),
    coalesce(sum(b.liquido_plataforma * (1 - v_imposto/100)), 0),
    coalesce(sum(b.itens), 0),
    coalesce(sum(b.pago), 0)
  into v_linhas, v_bruto, v_liquido, v_itens, v_pago
  from base b
  left join dash.plataformas pl on pl.slug = b.plataforma;

  return jsonb_build_object(
    'ok', true,
    'inicio', v_inicio, 'fim', v_fim,
    'imposto_percentual', v_imposto,
    'plataformas', v_linhas,
    'total_bruto', round(v_bruto, 2),
    'total_liquido', round(v_liquido, 2),
    'total_itens', v_itens,
    'total_pago', round(v_pago, 2)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.registrar_pagamento(jsonb), public.ingest_pagamentos(jsonb)
  from public, anon, authenticated;
grant execute on function public.registrar_pagamento(jsonb), public.ingest_pagamentos(jsonb),
  public.dash_receita(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 5. INSTRUÇÃO DA INTEGRAÇÃO
-- ---------------------------------------------------------------------
update dash.integracoes set
  instrucoes = 'A TMB é boleto parcelado, então são dois webhooks: o de Vendas registra o faturamento e o Financeiro atualiza quanto o aluno já pagou. Com os dois, a dash mostra o valor vendido e o valor pago.',
  passos = '[
    "No portal do produtor, vá em PRODUTOS > Mais opções do produto > Integrações.",
    "Abra Webhook VENDAS. Em URL cole o primeiro endereço abaixo, em Chave escreva x-dash-token e em Valor cole o token. Marque como ativo e salve.",
    "Volte e abra Webhook FINANCEIRO. Em URL cole o segundo endereço, com a mesma Chave e Valor. Marque como ativo e salve.",
    "Repita nos dois para cada produto vendido pela TMB — a configuração é por produto."
  ]'::jsonb
where slug = 'tmb';

select public.dash_receita('{}'::jsonb);
