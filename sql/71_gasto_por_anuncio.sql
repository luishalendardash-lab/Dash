-- =====================================================================
-- 71 — O GASTO PASSA A VIR POR ANÚNCIO
--
-- O diagnóstico mostrou o desencontro:
--
--   gasto:  "L2509 [05.09.25][CAPTAÇÃO][LP03][ABO]"   nome de CAMPANHA
--   leads:  "ADS01", "[ADS10]"                          nome de ANÚNCIO
--
-- São camadas diferentes da mesma conta. Comparar uma com a outra nunca
-- casa, por mais que a normalização melhore.
--
-- Agora a sincronização traz o gasto por anúncio e usa o nome da
-- campanha só para descobrir a data — e portanto o lançamento.
-- =====================================================================

set search_path = dash, public;

create or replace function public.ingest_investimento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_item jsonb; v_data date; v_lanc uuid; v_slug text; v_chave text;
  v_gasto numeric; v_so_cap boolean; v_nome text; v_campanha text;
  v_qtd int := 0; v_fora int := 0; v_sem_data int := 0;
  v_total numeric := 0; v_por_lanc jsonb := '{}'::jsonb;
  v_ignoradas jsonb := '[]'::jsonb; v_lancs uuid[] := '{}';
  v_limpos int := 0;
begin
  v_so_cap := coalesce((p->>'so_captacao')::boolean, true);

  for v_item in select * from jsonb_array_elements(coalesce(p->'campanhas','[]'::jsonb))
  loop
    v_nome := nullif(btrim(coalesce(v_item->>'nome','')), '');
    v_campanha := nullif(btrim(coalesce(v_item->>'campanha','')), '');
    v_gasto := coalesce(dash.valor_para_numero(v_item->>'gasto'), 0);

    if v_gasto <= 0 then continue; end if;

    -- o filtro de captação olha o nome da CAMPANHA, que é onde a
    -- convenção está; o anúncio se chama só ADS01
    if v_so_cap and upper(translate(coalesce(v_campanha, v_nome, ''),
         'ÇÃÁÉÍÓÚÂÊÔÕ', 'CAAEIOUAEOO')) not like '%CAPTACAO%' then
      v_fora := v_fora + 1;
      continue;
    end if;

    -- a data vem do nome da campanha; o anúncio não a carrega
    v_data := coalesce(
      dash.data_do_nome(coalesce(v_campanha, '')),
      dash.data_do_nome(coalesce(v_nome, '')),
      nullif(v_item->>'dia','')::date
    );

    if v_data is null then
      v_sem_data := v_sem_data + 1;
      v_ignoradas := v_ignoradas || jsonb_build_array(
        jsonb_build_object('nome', coalesce(v_campanha, v_nome), 'gasto', v_gasto));
      continue;
    end if;

    v_lanc := dash.lancamento_na_data(v_data::timestamptz);
    if v_lanc is null then
      v_sem_data := v_sem_data + 1;
      continue;
    end if;

    -- limpa outras origens do mesmo lançamento, uma vez por lote
    if not (v_lanc = any(v_lancs)) then
      v_lancs := v_lancs || v_lanc;
      with removidos as (
        delete from dash.ads_insights
        where lancamento_id = v_lanc
          and (ad_id like 'csv-%' or ad_id like 'geral-%' or ad_id like 'auto-%')
        returning 1
      )
      select v_limpos + count(*) into v_limpos from removidos;
    end if;

    -- Guardamos com o ID REAL do anúncio, não com uma chave inventada.
    -- É isso que permite casar com o meta_ad_id do lead.
    v_chave := coalesce(nullif(v_item->>'id',''), 'auto-' || md5(coalesce(v_nome,'')));

    -- a hierarquia, para a tela poder mostrar campanha e conjunto
    if nullif(v_item->>'campanha_id','') is not null then
      insert into dash.ads_entidades (id, lancamento_id, nivel, nome, conta_id)
      values (v_item->>'campanha_id', v_lanc, 'campaign',
              coalesce(v_campanha, v_item->>'campanha_id'),
              coalesce(nullif(v_item->>'conta',''), 'meta'))
      on conflict (id) do update set
        nome = excluded.nome, lancamento_id = excluded.lancamento_id;
    end if;

    if nullif(v_item->>'conjunto_id','') is not null then
      insert into dash.ads_entidades (id, lancamento_id, nivel, nome, parent_id, conta_id)
      values (v_item->>'conjunto_id', v_lanc, 'adset',
              coalesce(nullif(v_item->>'conjunto',''), v_item->>'conjunto_id'),
              nullif(v_item->>'campanha_id',''),
              coalesce(nullif(v_item->>'conta',''), 'meta'))
      on conflict (id) do update set
        nome = excluded.nome,
        parent_id = coalesce(excluded.parent_id, dash.ads_entidades.parent_id),
        lancamento_id = excluded.lancamento_id;
    end if;

    insert into dash.ads_entidades (id, lancamento_id, nivel, nome, parent_id, conta_id)
    values (v_chave, v_lanc, 'ad', coalesce(v_nome, v_chave),
            nullif(v_item->>'conjunto_id',''),
            coalesce(nullif(v_item->>'conta',''), 'meta'))
    on conflict (id) do update set
      nome = coalesce(nullif(excluded.nome,''), dash.ads_entidades.nome),
      parent_id = coalesce(excluded.parent_id, dash.ads_entidades.parent_id),
      lancamento_id = excluded.lancamento_id;

    insert into dash.ads_insights
      (ad_id, lancamento_id, data_ref, gasto, impressoes, cliques)
    values (
      v_chave, v_lanc, coalesce(nullif(v_item->>'dia','')::date, v_data),
      least(v_gasto, 99999999),
      coalesce(nullif(regexp_replace(coalesce(v_item->>'impressoes',''), '\D', '', 'g'),'')::bigint, 0),
      coalesce(nullif(regexp_replace(coalesce(v_item->>'cliques',''), '\D', '', 'g'),'')::bigint, 0)
    )
    on conflict (ad_id, data_ref) do update set
      gasto = excluded.gasto,
      impressoes = excluded.impressoes,
      cliques = excluded.cliques,
      lancamento_id = excluded.lancamento_id;

    select slug into v_slug from dash.lancamentos where id = v_lanc;
    v_por_lanc := jsonb_set(v_por_lanc, array[v_slug],
      to_jsonb(round(coalesce((v_por_lanc->>v_slug)::numeric, 0) + v_gasto, 2)));

    v_qtd := v_qtd + 1;
    v_total := v_total + v_gasto;
  end loop;

  delete from dash.ads_entidades e
  where not exists (select 1 from dash.ads_insights i where i.ad_id = e.id)
    and e.nivel = 'ad';

  return jsonb_build_object(
    'ok', true, 'anuncios', v_qtd, 'campanhas', v_qtd, 'gasto', round(v_total, 2),
    'fora_de_captacao', v_fora, 'sem_data_no_nome', v_sem_data,
    'substituidos', v_limpos,
    'ignoradas', v_ignoradas, 'por_lancamento', v_por_lanc
  );
end $$;

grant execute on function public.ingest_investimento(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- LIMPAR O GASTO EM NÍVEL DE CAMPANHA
--    Ele não casa com criativo nenhum. Depois de rodar a sincronização
--    nova, este comando remove o que ficou da forma antiga.
-- ---------------------------------------------------------------------
create or replace function public.limpar_gasto_de_campanha(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_qtd int; v_valor numeric;
begin
  select count(*), coalesce(round(sum(a.gasto),2),0) into v_qtd, v_valor
  from dash.ads_insights a
  join dash.ads_entidades e on e.id = a.ad_id
  where e.nivel = 'campaign' or a.ad_id like 'csv-%'
     or a.ad_id like 'auto-%' or a.ad_id like 'geral-%';

  delete from dash.ads_insights a
  using dash.ads_entidades e
  where e.id = a.ad_id
    and (e.nivel = 'campaign' or a.ad_id like 'csv-%'
         or a.ad_id like 'auto-%' or a.ad_id like 'geral-%');

  delete from dash.ads_insights
  where ad_id like 'csv-%' or ad_id like 'auto-%' or ad_id like 'geral-%';

  delete from dash.ads_entidades e
  where not exists (select 1 from dash.ads_insights i where i.ad_id = e.id)
    and e.nivel = 'ad';

  return jsonb_build_object('ok', true, 'registros', v_qtd, 'gasto_removido', v_valor);
end $$;

revoke all on function public.limpar_gasto_de_campanha(jsonb) from public, anon, authenticated;
grant execute on function public.limpar_gasto_de_campanha(jsonb) to service_role;

notify pgrst, 'reload schema';

select 'pronto — agora use Ajustes > Buscar investimento no Meta' as proximo_passo;
