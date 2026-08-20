-- =====================================================================
-- 25 — CONSERTA A HOME
--
-- Rode este arquivo. Ele funciona esteja o banco no estado que estiver.
--
-- O que aconteceu: o arquivo 20 tinha um erro no meio. Como o Supabase
-- roda o script inteiro numa transação, o erro desfez tudo — inclusive
-- a criação da coluna valor_recebido, que o 23 usa. Resultado: a Home
-- quebrou com "column vf.valor_recebido does not exist".
--
-- Este arquivo cria o que falta e refaz as funções. Rodar de novo, mesmo
-- que já esteja tudo certo, não causa problema.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O QUE PODE ESTAR FALTANDO
-- ---------------------------------------------------------------------
alter table dash.vendas
  add column if not exists valor_recebido numeric(14,2) not null default 0,
  add column if not exists parcelas_total int;

comment on column dash.vendas.valor_recebido is
  'Quanto o comprador ja pagou. Em plataforma a vista e igual ao valor_bruto.';

-- resquícios do arquivo 19, que foi descartado
drop function if exists public.ingest_parcelas(jsonb);
drop function if exists public.religar_parcelas(jsonb);
drop table if exists dash.parcelas;
alter table dash.vendas
  drop column if exists valor_contratado,
  drop column if exists parcelas_pagas;

-- vendas antigas: se não é TMB, o que foi faturado já foi pago
update dash.vendas
set valor_recebido = valor_bruto
where plataforma <> 'tmb' and valor_recebido = 0 and status = 'aprovada';

-- ---------------------------------------------------------------------
-- 2. PAGAMENTO DA TMB (estava no 20)
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

  if lower(coalesce(p->>'status','')) not like '%recebid%' then
    return jsonb_build_object('ok', true, 'ignorado', true);
  end if;

  -- guarda quais parcelas já foram contadas, para o mesmo aviso não
  -- somar duas vezes (a TMB reenvia eventos)
  if (p ? 'parcela_id') and
     coalesce((select raw->'_parcelas_pagas' ? (p->>'parcela_id')
               from dash.vendas where id = v_id), false)
  then
    return jsonb_build_object('ok', true, 'ja_contabilizada', true);
  end if;

  update dash.vendas set
    valor_recebido = least(valor_bruto,
      coalesce(valor_recebido,0) + coalesce((p->>'valor')::numeric, 0)),
    raw = jsonb_set(
      coalesce(raw,'{}'::jsonb), '{_parcelas_pagas}',
      coalesce(raw->'_parcelas_pagas','{}'::jsonb) ||
      jsonb_build_object(coalesce(p->>'parcela_id','x'), true)
    )
  where id = v_id
  returning valor_recebido into v_pago;

  return jsonb_build_object('ok', true, 'pago', v_pago, 'de', v_bruto);
end $$;

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
-- 3. NORMALIZAÇÃO DO NOME DO PRODUTO
-- ---------------------------------------------------------------------
create or replace function dash.chave_produto(nome text)
returns text language sql immutable as $$
  select nullif(
    upper(btrim(regexp_replace(
      translate(
        coalesce(nome,''),
        'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
        'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN'
      ),
      '\s+', ' ', 'g'))),
  '');
$$;

-- ---------------------------------------------------------------------
-- 4. RECEITA DA HOME — com filtro de produto
-- ---------------------------------------------------------------------
create or replace function public.dash_receita(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_inicio timestamptz; v_fim timestamptz; v_imposto numeric;
  v_filtro text[];
  v_linhas jsonb; v_produtos jsonb;
  v_bruto numeric := 0; v_liquido numeric := 0; v_itens int := 0; v_pago numeric := 0;
begin
  v_inicio := coalesce((p->>'inicio')::timestamptz, date_trunc('month', now()));
  v_fim    := coalesce((p->>'fim')::timestamptz, now() + interval '1 day');

  select coalesce((valor)::text::numeric, 0) into v_imposto
  from dash.config where chave = 'imposto_percentual';
  v_imposto := coalesce(v_imposto, 0);

  select array_agg(value) into v_filtro
  from jsonb_array_elements_text(coalesce(p->'produtos','[]'::jsonb));
  if v_filtro is not null and array_length(v_filtro, 1) is null then v_filtro := null; end if;

  with vendas_filtradas as (
    select v.*, coalesce(dash.chave_produto(v.produto), '(sem produto)') as pchave
    from dash.vendas v
    where v.status = 'aprovada'
      and v.ocorreu_em >= v_inicio and v.ocorreu_em < v_fim
      and (v_filtro is null
           or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro))
  ),
  base as (
    select
      vf.plataforma,
      count(*) as itens,
      sum(vf.valor_bruto) as bruto,
      sum(
        case when vf.valor_liquido > 0 then vf.valor_liquido
             else greatest(0, vf.valor_bruto
                  - (vf.valor_bruto * coalesce(pl.taxa_percentual,0) / 100)
                  - coalesce(pl.taxa_fixa,0))
        end
      ) as liquido_plataforma,
      -- TMB recebe conforme o aluno paga; nas outras, pago = faturado
      sum(case when vf.plataforma = 'tmb'
               then coalesce(vf.valor_recebido, 0) else vf.valor_bruto end) as pago
    from vendas_filtradas vf
    left join dash.plataformas pl on pl.slug = vf.plataforma
    group by vf.plataforma
  ),
  porproduto as (
    select vf.pchave, min(vf.produto) as nome, count(*) as itens,
           sum(vf.valor_bruto) as bruto, count(distinct vf.plataforma) as plataformas
    from vendas_filtradas vf group by vf.pchave
  )
  select
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', b.plataforma,
        'nome', coalesce(pl.nome, initcap(b.plataforma)),
        'inicial', coalesce(pl.inicial, upper(left(b.plataforma,1))),
        'cor', coalesce(pl.cor, '#666666'),
        'itens', b.itens,
        'bruto', round(b.bruto, 2),
        'liquido', round(b.liquido_plataforma * (1 - v_imposto/100), 2),
        'pago', round(b.pago, 2),
        'parcelado', b.plataforma = 'tmb'
      ) order by b.bruto desc)
      from base b left join dash.plataformas pl on pl.slug = b.plataforma
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'chave', pp.pchave,
        'nome', coalesce(pp.nome, '(sem produto)'),
        'vendas', pp.itens,
        'receita', round(pp.bruto, 2),
        'ticket', round(pp.bruto / nullif(pp.itens,0), 2),
        'plataformas', pp.plataformas
      ) order by pp.bruto desc)
      from porproduto pp
    ), '[]'::jsonb),
    coalesce((select sum(bruto) from base), 0),
    coalesce((select sum(liquido_plataforma * (1 - v_imposto/100)) from base), 0),
    coalesce((select sum(itens) from base), 0),
    coalesce((select sum(pago) from base), 0)
  into v_linhas, v_produtos, v_bruto, v_liquido, v_itens, v_pago;

  return jsonb_build_object(
    'ok', true,
    'inicio', v_inicio, 'fim', v_fim,
    'imposto_percentual', v_imposto,
    'plataformas', v_linhas,
    'produtos', v_produtos,
    'filtrado', v_filtro is not null,
    'total_bruto', round(v_bruto, 2),
    'total_liquido', round(v_liquido, 2),
    'total_itens', v_itens,
    'total_pago', round(v_pago, 2)
  );
end $$;

-- ---------------------------------------------------------------------
-- 5. INSTRUÇÕES DA TMB (estavam no 20)
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

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.registrar_pagamento(jsonb), public.ingest_pagamentos(jsonb)
  from public, anon, authenticated;
grant execute on function public.registrar_pagamento(jsonb), public.ingest_pagamentos(jsonb),
  public.dash_receita(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

-- ---------------------------------------------------------------------
-- 7. CONFERE — precisa devolver ok: true
-- ---------------------------------------------------------------------
select public.dash_receita('{}'::jsonb) -> 'ok' as receita_ok,
       public.dash_captura('{}'::jsonb) -> 'ok' as captura_ok,
       public.dash_produtos('{}'::jsonb) -> 'ok' as produtos_ok;
