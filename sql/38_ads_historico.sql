-- =====================================================================
-- 38 — GASTO DOS LANÇAMENTOS ANTIGOS
--
-- A sincronização normal filtra campanhas pelo código do lançamento no
-- nome. Nos lançamentos antigos esse código não existe — as campanhas se
-- chamam "[05.09.25][CAPTAÇÃO][LP03]".
--
-- Mas a planilha de captura trouxe o ID numérico de cada anúncio. Com
-- ele dá para pedir o gasto direto ao Meta, sem depender do nome. É mais
-- confiável: nome muda, ID não.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. QUAIS ANÚNCIOS PRECISAM DE GASTO
--    Só os que aparecem nos leads e ainda não têm insight.
-- ---------------------------------------------------------------------
create or replace function public.ads_para_buscar(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_ids jsonb; v_de date; v_ate date;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  -- só ids numéricos: nome de criativo não serve para consultar a API
  select jsonb_agg(distinct i.meta_ad_id)
  into v_ids
  from dash.inscricoes i
  where i.lancamento_id = v_lanc
    and i.meta_ad_id ~ '^[0-9]+$'
    and (coalesce((p->>'refazer')::boolean, false)
         or not exists (select 1 from dash.ads_insights ai
                        where ai.ad_id = i.meta_ad_id));

  -- Janela pelo miolo da captação, não pelas pontas.
  -- Alguns leads ficam com a data de hoje (vieram de planilha sem data)
  -- e outros aparecem semanas depois. Usar min e max esticaria o período
  -- por meses e traria gasto de campanha que não é deste lançamento.
  select
    percentile_disc(0.02) within group (order by capturado_em)::date - 3,
    percentile_disc(0.98) within group (order by capturado_em)::date + 3
  into v_de, v_ate
  from dash.inscricoes
  where lancamento_id = v_lanc
    and capturado_em < now() - interval '1 day';   -- ignora o carimbo de hoje

  -- se ainda assim passar de 90 dias, corta: lançamento não dura tanto
  if v_ate - v_de > 90 then
    v_ate := v_de + 90;
  end if;

  return jsonb_build_object(
    'ok', true,
    'ad_ids', coalesce(v_ids, '[]'::jsonb),
    'de', v_de, 'ate', v_ate,
    'contas', (select coalesce(config->'meta_contas','[]'::jsonb)
               from dash.lancamentos where id = v_lanc)
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. GRAVAR O QUE VOLTOU DA API
--    p: { lancamento, itens: [{ad_id, nome, conjunto, campanha,
--                               conjunto_id, campanha_id, dia,
--                               gasto, impressoes, cliques}] }
-- ---------------------------------------------------------------------
create or replace function public.ingest_ads_historico(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_item jsonb;
  v_ent int := 0; v_ins int := 0; v_gasto numeric := 0;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p->'itens','[]'::jsonb))
  loop
    -- a hierarquia precisa existir para a tela mostrar campanha e conjunto
    if nullif(v_item->>'campanha_id','') is not null then
      insert into dash.ads_entidades (id, lancamento_id, nivel, nome, conta_id)
      values (v_item->>'campanha_id', v_lanc, 'campaign',
              coalesce(nullif(v_item->>'campanha',''), v_item->>'campanha_id'),
              coalesce(nullif(v_item->>'conta',''), 'historico'))
      on conflict (id) do update set
        nome = coalesce(nullif(excluded.nome,''), dash.ads_entidades.nome),
        lancamento_id = excluded.lancamento_id;
    end if;

    if nullif(v_item->>'conjunto_id','') is not null then
      insert into dash.ads_entidades (id, lancamento_id, nivel, nome, parent_id, conta_id)
      values (v_item->>'conjunto_id', v_lanc, 'adset',
              coalesce(nullif(v_item->>'conjunto',''), v_item->>'conjunto_id'),
              nullif(v_item->>'campanha_id',''),
              coalesce(nullif(v_item->>'conta',''), 'historico'))
      on conflict (id) do update set
        nome = coalesce(nullif(excluded.nome,''), dash.ads_entidades.nome),
        parent_id = coalesce(excluded.parent_id, dash.ads_entidades.parent_id),
        lancamento_id = excluded.lancamento_id;
    end if;

    insert into dash.ads_entidades (id, lancamento_id, nivel, nome, parent_id, conta_id)
    values (v_item->>'ad_id', v_lanc, 'ad',
            coalesce(nullif(v_item->>'nome',''), v_item->>'ad_id'),
            nullif(v_item->>'conjunto_id',''),
            coalesce(nullif(v_item->>'conta',''), 'historico'))
    on conflict (id) do update set
      nome = coalesce(nullif(excluded.nome,''), dash.ads_entidades.nome),
      parent_id = coalesce(excluded.parent_id, dash.ads_entidades.parent_id),
      lancamento_id = excluded.lancamento_id;
    v_ent := v_ent + 1;

    insert into dash.ads_insights
      (ad_id, lancamento_id, data_ref, gasto, impressoes, cliques, cliques_link)
    values (
      v_item->>'ad_id', v_lanc,
      coalesce(nullif(v_item->>'dia','')::date, current_date),
      coalesce(dash.valor_para_numero(v_item->>'gasto'), 0),
      coalesce(nullif(v_item->>'impressoes','')::bigint, 0),
      coalesce(nullif(v_item->>'cliques','')::bigint, 0),
      coalesce(nullif(v_item->>'cliques_link','')::bigint, 0)
    )
    on conflict (ad_id, data_ref) do update set
      gasto = excluded.gasto,
      impressoes = excluded.impressoes,
      cliques = excluded.cliques,
      cliques_link = excluded.cliques_link,
      lancamento_id = excluded.lancamento_id;

    v_ins := v_ins + 1;
    v_gasto := v_gasto + coalesce(dash.valor_para_numero(v_item->>'gasto'), 0);
  end loop;

  return jsonb_build_object('ok', true, 'entidades', v_ent,
                            'insights', v_ins, 'gasto', round(v_gasto, 2));
end $$;

-- ---------------------------------------------------------------------
-- 3. O QUE FALTOU
--    Anúncios que têm lead mas continuam sem gasto. Se a lista for
--    grande, o CPL do lançamento está incompleto e é bom saber.
-- ---------------------------------------------------------------------
create or replace function public.ads_sem_gasto(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb; v_total int; v_sem int;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select jsonb_agg(jsonb_build_object('ad_id', ad_id, 'nome', nome, 'leads', leads)
                   order by leads desc)
  into v_res
  from (
    select i.meta_ad_id as ad_id,
           coalesce(min(e.nome), min(i.utm_content), i.meta_ad_id) as nome,
           count(*) as leads
    from dash.inscricoes i
    left join dash.ads_entidades e on e.id = i.meta_ad_id
    where i.lancamento_id = v_lanc
      and i.meta_ad_id is not null
      and not exists (select 1 from dash.ads_insights ai where ai.ad_id = i.meta_ad_id)
    group by i.meta_ad_id
    limit 40
  ) t;

  select count(distinct meta_ad_id) into v_total
  from dash.inscricoes where lancamento_id = v_lanc and meta_ad_id is not null;

  select count(distinct i.meta_ad_id) into v_sem
  from dash.inscricoes i
  where i.lancamento_id = v_lanc and i.meta_ad_id is not null
    and not exists (select 1 from dash.ads_insights ai where ai.ad_id = i.meta_ad_id);

  return jsonb_build_object('ok', true, 'anuncios', coalesce(v_res, '[]'::jsonb),
                            'total', v_total, 'sem_gasto', v_sem);
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.ads_para_buscar(jsonb), public.ingest_ads_historico(jsonb),
  public.ads_sem_gasto(jsonb) from public, anon, authenticated;
grant execute on function public.ads_para_buscar(jsonb), public.ingest_ads_historico(jsonb),
  public.ads_sem_gasto(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;
