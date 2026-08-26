-- =====================================================================
-- 66 — CONFERIR E RECRIAR ingest_ads_historico
--
-- O PostgREST devolve PGRST202 quando não encontra a função no cache.
-- Isso acontece em três casos: a função não existe, existe com outra
-- assinatura, ou existe mas sem permissão para o papel que a chama.
--
-- Este arquivo mostra qual é o caso e recria a função do zero.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O QUE EXISTE HOJE
-- ---------------------------------------------------------------------
select
  n.nspname as esquema,
  p.proname as funcao,
  pg_get_function_arguments(p.oid) as argumentos,
  pg_get_userbyid(p.proowner) as dono,
  has_function_privilege('service_role', p.oid, 'execute') as service_role_pode
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where p.proname in ('ingest_ads_historico', 'ads_para_buscar');

-- ---------------------------------------------------------------------
-- 2. RECRIAR
-- ---------------------------------------------------------------------
drop function if exists public.ingest_ads_historico(jsonb);

create function public.ingest_ads_historico(p jsonb)
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
      least(coalesce(dash.valor_para_numero(v_item->>'gasto'), 0), 99999999),
      coalesce(nullif(regexp_replace(coalesce(v_item->>'impressoes',''), '\D', '', 'g'),'')::bigint, 0),
      coalesce(nullif(regexp_replace(coalesce(v_item->>'cliques',''), '\D', '', 'g'),'')::bigint, 0),
      coalesce(nullif(regexp_replace(coalesce(v_item->>'cliques_link',''), '\D', '', 'g'),'')::bigint, 0)
    )
    on conflict (ad_id, data_ref) do update set
      gasto = excluded.gasto,
      impressoes = excluded.impressoes,
      cliques = excluded.cliques,
      cliques_link = excluded.cliques_link,
      lancamento_id = excluded.lancamento_id;

    v_ins := v_ins + 1;
    v_gasto := v_gasto + least(coalesce(dash.valor_para_numero(v_item->>'gasto'), 0), 99999999);
  end loop;

  return jsonb_build_object('ok', true, 'entidades', v_ent,
                            'insights', v_ins, 'gasto', round(v_gasto, 2));
end $$;

-- ---------------------------------------------------------------------
-- 3. PERMISSÃO
--    Sem grant, o PostgREST responde como se a função não existisse.
-- ---------------------------------------------------------------------
grant execute on function public.ingest_ads_historico(jsonb)
  to service_role, authenticated, anon;

-- ---------------------------------------------------------------------
-- 4. CONFERIR DE NOVO
-- ---------------------------------------------------------------------
select
  p.proname as funcao,
  pg_get_function_arguments(p.oid) as argumentos,
  has_function_privilege('service_role', p.oid, 'execute') as service_role_pode
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'ingest_ads_historico';

-- ---------------------------------------------------------------------
-- 5. RECARREGAR O CACHE
-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';
select pg_notify('pgrst', 'reload schema');

select 'pronto — tente o botao de novo' as proximo_passo;
