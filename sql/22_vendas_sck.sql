-- =====================================================================
-- 22 — VENDAS: ORIGEM DO LINK E SÉRIE DIÁRIA
--
-- Duas adições:
--   1. agrupamento por SCK — o parâmetro que identifica de qual link
--      a venda saiu (grupo, e-mail, bio, remarketing...)
--   2. vendas por dia, para ver o comportamento do carrinho aberto
--
-- O SCK é complementar à atribuição por lead: o lead diz de qual anúncio
-- a pessoa veio; o SCK diz por qual link ela clicou para comprar.
-- =====================================================================

set search_path = dash, public;

create index if not exists ix_vendas_src on dash.vendas (lancamento_id, src_hotmart);

create or replace function public.dash_vendas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_imposto numeric;
  v_resumo jsonb; v_origem jsonb; v_lista jsonb; v_dia jsonb; v_sck jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

  select coalesce((valor)::text::numeric, 0) into v_imposto
  from dash.config where chave = 'imposto_percentual';
  v_imposto := coalesce(v_imposto, 0);

  -- ---- resumo
  select jsonb_build_object(
    'aprovadas',   count(*) filter (where status = 'aprovada'),
    'pendentes',   count(*) filter (where status = 'pendente'),
    'reembolsos',  count(*) filter (where status in ('reembolsada','chargeback')),
    'bruto',       round(coalesce(sum(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'liquido',     round(coalesce(sum(
                     case when valor_liquido > 0 then valor_liquido else valor_bruto * 0.9 end
                   ) filter (where status = 'aprovada'), 0) * (1 - v_imposto/100), 2),
    'ticket',      round(coalesce(avg(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'com_lead',    count(*) filter (where status = 'aprovada' and inscricao_id is not null),
    'sem_lead',    count(*) filter (where status = 'aprovada' and inscricao_id is null),
    'valor_reembolsado', round(coalesce(sum(valor_bruto)
                     filter (where status in ('reembolsada','chargeback')), 0), 2)
  )
  into v_resumo
  from dash.vendas where lancamento_id = v_lanc;

  -- ---- por anúncio (atribuição pelo lead)
  with atribuido as (
    select
      coalesce(a.nome, i.utm_content, i.meta_ad_id, '(sem anuncio)') as anuncio,
      coalesce(ac.nome, i.utm_campaign, '(sem campanha)') as campanha,
      i.engenheiro, v.valor_bruto
    from dash.vendas v
    join dash.inscricoes i on i.id = v.inscricao_id
    left join dash.ads_entidades a on a.id = i.meta_ad_id
    left join dash.ads_entidades aj on aj.id = a.parent_id
    left join dash.ads_entidades ac on ac.id = aj.parent_id
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
  )
  select jsonb_agg(x order by (x->>'receita')::numeric desc) into v_origem
  from (
    select jsonb_build_object(
      'anuncio', anuncio, 'campanha', campanha,
      'vendas', count(*),
      'engenheiros', count(*) filter (where engenheiro),
      'receita', round(sum(valor_bruto), 2)
    ) as x
    from atribuido group by anuncio, campanha
  ) t;

  -- ---- por SCK (de qual link saiu a venda)
  select jsonb_agg(x order by (x->>'receita')::numeric desc) into v_sck
  from (
    select jsonb_build_object(
      'sck', coalesce(nullif(btrim(src_hotmart), ''), '(sem sck)'),
      'vendas', count(*),
      'receita', round(sum(valor_bruto), 2),
      'ticket', round(avg(valor_bruto), 2),
      'com_lead', count(*) filter (where inscricao_id is not null)
    ) as x
    from dash.vendas
    where lancamento_id = v_lanc and status = 'aprovada'
    group by coalesce(nullif(btrim(src_hotmart), ''), '(sem sck)')
  ) t;

  -- ---- dia a dia, com acumulado
  -- o acumulado precisa sair numa etapa própria: função de janela não
  -- pode ficar dentro de jsonb_agg
  with diario as (
    select ocorreu_em::date as dia, count(*) qtd, round(sum(valor_bruto),2) receita
    from dash.vendas
    where lancamento_id = v_lanc and status = 'aprovada'
    group by 1
  ),
  com_acumulado as (
    select dia, qtd, receita,
           sum(receita) over (order by dia) as acumulado,
           sum(qtd) over (order by dia) as vendas_acumuladas
    from diario
  )
  select jsonb_agg(jsonb_build_object(
    'dia', dia, 'vendas', qtd, 'receita', receita,
    'acumulado', acumulado, 'vendas_acumuladas', vendas_acumuladas
  ) order by dia)
  into v_dia
  from com_acumulado;

  -- ---- últimas vendas
  select jsonb_agg(x order by (x->>'ocorreu_em') desc) into v_lista
  from (
    select jsonb_build_object(
      'id', v.id,
      'nome', coalesce(p2.nome, v.email_comprador, '—'),
      'email', coalesce(p2.email, v.email_comprador),
      'produto', v.produto, 'oferta', v.oferta,
      'status', v.status, 'metodo', v.metodo,
      'valor', v.valor_bruto,
      'parcelas', v.parcelas,
      'valor_parcela', nullif(v.raw->>'valor_parcela','')::numeric,
      'sck', nullif(btrim(v.src_hotmart), ''),
      'plataforma', v.plataforma,
      'ocorreu_em', v.ocorreu_em,
      'inscricao_id', v.inscricao_id,
      'campanha', i.utm_campaign,
      'anuncio', coalesce(a.nome, i.utm_content, i.meta_ad_id),
      'engenheiro', coalesce(i.engenheiro, false),
      'atribuida', v.inscricao_id is not null
    ) as x
    from dash.vendas v
    left join dash.inscricoes i on i.id = v.inscricao_id
    left join dash.pessoas p2 on p2.id = v.pessoa_id
    left join dash.ads_entidades a on a.id = i.meta_ad_id
    where v.lancamento_id = v_lanc
    order by v.ocorreu_em desc
    limit 200
  ) t;

  return jsonb_build_object(
    'ok', true,
    'resumo', coalesce(v_resumo, '{}'::jsonb),
    'origem', coalesce(v_origem, '[]'::jsonb),
    'por_sck', coalesce(v_sck, '[]'::jsonb),
    'dia_a_dia', coalesce(v_dia, '[]'::jsonb),
    'vendas', coalesce(v_lista, '[]'::jsonb)
  );
end $$;

grant execute on function public.dash_vendas(jsonb) to service_role;

select public.dash_vendas('{}'::jsonb);
