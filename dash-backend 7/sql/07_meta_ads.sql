-- =====================================================================
-- 07 — META ADS
-- Recebe campanhas/conjuntos/anúncios e as métricas diárias.
-- O Worker busca na API do Meta; aqui só entra o que já veio pronto.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. VÍNCULO CONTAS <-> LANÇAMENTO
--    Fica no config do lançamento para não criar tabela nova:
--    {
--      "meta_contas": ["act_111", "act_222"],          uma ou várias
--      "meta_campanhas": ["120210...", "120211..."],   (opcional)
--      "meta_prefixo": "[SET26]"                        (opcional)
--    }
--    Sem lista de campanhas nem prefixo, todas as campanhas de todas as
--    contas entram — o que mistura tráfego direto com captação.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 2. UPSERT DE ENTIDADES (campanha, conjunto, anúncio)
--    p: { lancamento: 'slug', entidades: [ {...}, {...} ] }
-- ---------------------------------------------------------------------
create or replace function public.ingest_ads_entidades(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_qtd int := 0;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  insert into dash.ads_entidades (id, nivel, nome, parent_id, conta_id, lancamento_id, status, objetivo, criativo, atualizado_em)
  select
    e->>'id',
    e->>'nivel',
    coalesce(e->>'nome', '(sem nome)'),
    nullif(e->>'parent_id',''),
    coalesce(e->>'conta_id', ''),
    v_lanc,
    nullif(e->>'status',''),
    nullif(e->>'objetivo',''),
    coalesce(e->'criativo', '{}'::jsonb),
    now()
  from jsonb_array_elements(coalesce(p->'entidades','[]'::jsonb)) as e
  on conflict (id) do update set
    nome = excluded.nome,
    parent_id = coalesce(excluded.parent_id, dash.ads_entidades.parent_id),
    status = excluded.status,
    objetivo = coalesce(excluded.objetivo, dash.ads_entidades.objetivo),
    -- criativo só sobrescreve quando veio conteúdo novo
    criativo = case when excluded.criativo = '{}'::jsonb
                    then dash.ads_entidades.criativo else excluded.criativo end,
    lancamento_id = coalesce(excluded.lancamento_id, dash.ads_entidades.lancamento_id),
    atualizado_em = now();

  get diagnostics v_qtd = row_count;
  return jsonb_build_object('ok', true, 'entidades', v_qtd, 'lancamento_id', v_lanc);
end $$;

-- ---------------------------------------------------------------------
-- 3. UPSERT DE MÉTRICAS DIÁRIAS
--    p: { lancamento: 'slug', insights: [ { data_ref, ad_id, gasto, ... } ] }
-- ---------------------------------------------------------------------
create or replace function public.ingest_ads_insights(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_qtd int := 0; v_gasto numeric;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  -- só grava métrica de anúncio que já existe na tabela de entidades,
  -- senão a chave estrangeira quebra o lote inteiro por causa de um item
  insert into dash.ads_insights (
    data_ref, ad_id, lancamento_id, impressoes, alcance, cliques, cliques_link,
    gasto, ctr, cpm, cpc, leads_meta, video_3s, video_75, raw, atualizado_em
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
    now()
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
    raw = excluded.raw,
    lancamento_id = coalesce(excluded.lancamento_id, dash.ads_insights.lancamento_id),
    atualizado_em = now();

  get diagnostics v_qtd = row_count;

  select coalesce(sum(gasto), 0) into v_gasto
  from dash.ads_insights where lancamento_id = v_lanc;

  return jsonb_build_object('ok', true, 'insights', v_qtd, 'gasto_total', v_gasto);
end $$;

-- ---------------------------------------------------------------------
-- 4. TELA DE ANÚNCIOS — gasto real do Meta x lead real do banco
-- ---------------------------------------------------------------------
create or replace function public.dash_anuncios(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb;
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

  with gasto as (
    select ad_id, sum(gasto) gasto, sum(impressoes) impressoes,
           sum(cliques_link) cliques, sum(leads_meta) leads_meta
    from dash.ads_insights where lancamento_id = v_lanc group by ad_id
  ),
  reais as (
    select meta_ad_id,
           count(*) leads,
           count(*) filter (where engenheiro) engenheiros,
           count(*) filter (where comprou) compras
    from dash.inscricoes
    where lancamento_id = v_lanc and meta_ad_id is not null
    group by meta_ad_id
  )
  select jsonb_agg(jsonb_build_object(
    'ad_id', a.id,
    'anuncio', a.nome,
    'conjunto', aj.nome,
    'campanha', ac.nome,
    'status', a.status,
    'criativo', a.criativo,
    'gasto', round(coalesce(g.gasto,0), 2),
    'impressoes', coalesce(g.impressoes,0),
    'cliques', coalesce(g.cliques,0),
    'leads_meta', coalesce(g.leads_meta,0),
    'leads', coalesce(r.leads,0),
    'engenheiros', coalesce(r.engenheiros,0),
    'compras', coalesce(r.compras,0),
    'cpl', case when coalesce(r.leads,0) > 0
                then round(coalesce(g.gasto,0)/r.leads, 2) end,
    'cpl_engenheiro', case when coalesce(r.engenheiros,0) > 0
                then round(coalesce(g.gasto,0)/r.engenheiros, 2) end
  ) order by coalesce(g.gasto,0) desc)
  into v_res
  from dash.ads_entidades a
  left join dash.ads_entidades aj on aj.id = a.parent_id
  left join dash.ads_entidades ac on ac.id = aj.parent_id
  left join gasto g on g.ad_id = a.id
  left join reais r on r.meta_ad_id = a.id
  where a.nivel = 'ad' and a.lancamento_id = v_lanc;

  return jsonb_build_object('ok', true, 'anuncios', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.ingest_ads_entidades(jsonb), public.ingest_ads_insights(jsonb),
  public.dash_anuncios(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_ads_entidades(jsonb), public.ingest_ads_insights(jsonb),
  public.dash_anuncios(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 6. CONFIGURA AS CONTAS NO LANÇAMENTO (troque pelos act_ reais)
-- ---------------------------------------------------------------------
update dash.lancamentos
set config = coalesce(config,'{}'::jsonb) ||
  '{"meta_contas":["act_CONTA_UM","act_CONTA_DOIS"]}'::jsonb
where slug = 'lanc-2026-09';

-- Opcional: limitar às campanhas do lançamento, por prefixo no nome.
-- update dash.lancamentos
-- set config = config || '{"meta_prefixo":"[SET26]"}'::jsonb
-- where slug = 'lanc-2026-09';

select slug, config from dash.lancamentos;
