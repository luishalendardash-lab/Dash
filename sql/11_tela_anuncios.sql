-- =====================================================================
-- 11 — TELA DE ANÚNCIOS COMPLETA
--
-- Três blocos por anúncio:
--   META         investimento, resultado, CTR de link, custo por visita
--   TRAQUEAMENTO leads, leads no WhatsApp, engenheiros (qtd e custo)
--   COMPRA       compras e receita, cruzadas por e-mail do lead
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. COLUNAS NOVAS
-- ---------------------------------------------------------------------
alter table dash.ads_insights
  add column if not exists visitas_pagina bigint not null default 0,   -- landing_page_view
  add column if not exists resultados     bigint not null default 0,   -- conversão do objetivo
  add column if not exists resultado_tipo text,
  add column if not exists ctr_link       numeric(8,4);

-- ---------------------------------------------------------------------
-- 2. INGESTÃO — aceita os campos novos
-- ---------------------------------------------------------------------
create or replace function public.ingest_ads_insights(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_qtd int := 0; v_gasto numeric;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  insert into dash.ads_insights (
    data_ref, ad_id, lancamento_id, impressoes, alcance, cliques, cliques_link,
    gasto, ctr, cpm, cpc, leads_meta, video_3s, video_75, raw, atualizado_em,
    visitas_pagina, resultados, resultado_tipo, ctr_link
  )
  select
    (i->>'data_ref')::date,
    i->>'ad_id',
    v_lanc,
    coalesce((i->>'impressoes')::bigint, 0),
    coalesce((i->>'alcance')::bigint, 0),
    coalesce((i->>'cliques')::bigint, 0),
    coalesce((i->>'cliques_link')::bigint, 0),
    coalesce((i->>'gasto')::numeric, 0),
    nullif(i->>'ctr','')::numeric,
    nullif(i->>'cpm','')::numeric,
    nullif(i->>'cpc','')::numeric,
    coalesce((i->>'leads_meta')::int, 0),
    coalesce((i->>'video_3s')::bigint, 0),
    coalesce((i->>'video_75')::bigint, 0),
    coalesce(i->'raw', '{}'::jsonb),
    now(),
    coalesce((i->>'visitas_pagina')::bigint, 0),
    coalesce((i->>'resultados')::bigint, 0),
    nullif(i->>'resultado_tipo',''),
    nullif(i->>'ctr_link','')::numeric
  from jsonb_array_elements(coalesce(p->'insights','[]'::jsonb)) as i
  where exists (select 1 from dash.ads_entidades a where a.id = i->>'ad_id')
  on conflict (data_ref, ad_id) do update set
    impressoes = excluded.impressoes,
    alcance = excluded.alcance,
    cliques = excluded.cliques,
    cliques_link = excluded.cliques_link,
    gasto = excluded.gasto,
    ctr = excluded.ctr,
    cpm = excluded.cpm,
    cpc = excluded.cpc,
    leads_meta = excluded.leads_meta,
    video_3s = excluded.video_3s,
    video_75 = excluded.video_75,
    visitas_pagina = excluded.visitas_pagina,
    resultados = excluded.resultados,
    resultado_tipo = excluded.resultado_tipo,
    ctr_link = excluded.ctr_link,
    raw = excluded.raw,
    lancamento_id = coalesce(excluded.lancamento_id, dash.ads_insights.lancamento_id),
    atualizado_em = now();

  get diagnostics v_qtd = row_count;
  select coalesce(sum(gasto), 0) into v_gasto
  from dash.ads_insights where lancamento_id = v_lanc;

  return jsonb_build_object('ok', true, 'insights', v_qtd, 'gasto_total', v_gasto);
end $$;

-- ---------------------------------------------------------------------
-- 3. TELA DE ANÚNCIOS
--
-- Definições que valem registrar:
--   lead            = inscrição atribuída ao anúncio (adid na URL)
--   lead_whatsapp   = entrou no grupo OU respondeu no WhatsApp
--   engenheiro      = marcado pelo quiz
--   compra          = venda cruzada com o lead por e-mail/telefone
-- ---------------------------------------------------------------------
create or replace function public.dash_anuncios(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb; v_tot jsonb;
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

  with meta as (
    select ad_id,
           sum(gasto) gasto,
           sum(impressoes) impressoes,
           sum(cliques_link) cliques_link,
           sum(visitas_pagina) visitas,
           sum(resultados) resultados,
           max(resultado_tipo) resultado_tipo,
           case when sum(impressoes) > 0
                then round(100.0 * sum(cliques_link) / sum(impressoes), 2) end ctr_link
    from dash.ads_insights
    where lancamento_id = v_lanc
    group by ad_id
  ),
  rastreio as (
    select i.meta_ad_id,
           count(*) leads,
           count(*) filter (where i.entrou_grupo or i.whats_confirmado) leads_whats,
           count(*) filter (where i.engenheiro) engenheiros,
           count(*) filter (where i.comprou) compras
    from dash.inscricoes i
    where i.lancamento_id = v_lanc and i.meta_ad_id is not null
    group by i.meta_ad_id
  ),
  receita as (
    select i.meta_ad_id, sum(v.valor_bruto) valor
    from dash.vendas v
    join dash.inscricoes i on i.id = v.inscricao_id
    where i.lancamento_id = v_lanc and v.status = 'aprovada' and i.meta_ad_id is not null
    group by i.meta_ad_id
  )
  select
    jsonb_agg(x order by x->'gasto' desc),
    jsonb_build_object(
      'gasto', round(coalesce(sum((x->>'gasto')::numeric), 0), 2),
      'resultados', coalesce(sum((x->>'resultados')::bigint), 0),
      'visitas', coalesce(sum((x->>'visitas')::bigint), 0),
      'leads', coalesce(sum((x->>'leads')::bigint), 0),
      'leads_whats', coalesce(sum((x->>'leads_whats')::bigint), 0),
      'engenheiros', coalesce(sum((x->>'engenheiros')::bigint), 0),
      'compras', coalesce(sum((x->>'compras')::bigint), 0),
      'receita', round(coalesce(sum((x->>'receita')::numeric), 0), 2)
    )
  into v_res, v_tot
  from (
    select jsonb_build_object(
      'ad_id', a.id,
      'anuncio', a.nome,
      'conjunto', aj.nome,
      'campanha', ac.nome,
      'status', a.status,
      'criativo', a.criativo,

      -- meta
      'gasto', round(coalesce(m.gasto, 0), 2),
      'impressoes', coalesce(m.impressoes, 0),
      'cliques_link', coalesce(m.cliques_link, 0),
      'resultados', coalesce(m.resultados, 0),
      'resultado_tipo', m.resultado_tipo,
      'custo_resultado', case when coalesce(m.resultados,0) > 0
            then round(coalesce(m.gasto,0) / m.resultados, 2) end,
      'ctr_link', m.ctr_link,
      'visitas', coalesce(m.visitas, 0),
      'custo_visita', case when coalesce(m.visitas,0) > 0
            then round(coalesce(m.gasto,0) / m.visitas, 2) end,

      -- traqueamento
      'leads', coalesce(r.leads, 0),
      'custo_lead', case when coalesce(r.leads,0) > 0
            then round(coalesce(m.gasto,0) / r.leads, 2) end,
      'leads_whats', coalesce(r.leads_whats, 0),
      'custo_whats', case when coalesce(r.leads_whats,0) > 0
            then round(coalesce(m.gasto,0) / r.leads_whats, 2) end,
      'engenheiros', coalesce(r.engenheiros, 0),
      'custo_engenheiro', case when coalesce(r.engenheiros,0) > 0
            then round(coalesce(m.gasto,0) / r.engenheiros, 2) end,

      -- compra
      'compras', coalesce(r.compras, 0),
      'receita', round(coalesce(rc.valor, 0), 2),
      'custo_compra', case when coalesce(r.compras,0) > 0
            then round(coalesce(m.gasto,0) / r.compras, 2) end,
      'roas', case when coalesce(m.gasto,0) > 0
            then round(coalesce(rc.valor,0) / m.gasto, 2) end
    ) as x
    from dash.ads_entidades a
    left join dash.ads_entidades aj on aj.id = a.parent_id
    left join dash.ads_entidades ac on ac.id = aj.parent_id
    left join meta m     on m.ad_id = a.id
    left join rastreio r on r.meta_ad_id = a.id
    left join receita rc on rc.meta_ad_id = a.id
    where a.nivel = 'ad' and a.lancamento_id = v_lanc
  ) t;

  return jsonb_build_object('ok', true,
    'anuncios', coalesce(v_res, '[]'::jsonb),
    'totais', coalesce(v_tot, '{}'::jsonb));
end $$;

revoke all on function public.dash_anuncios(jsonb) from public, anon, authenticated;
grant execute on function public.dash_anuncios(jsonb) to service_role;

select public.dash_anuncios('{"lancamento":"lanc-2026-09"}'::jsonb);
