-- =====================================================================
-- 73 — INVESTIMENTO DO META, SEM CRUZAMENTO
--
-- Uma tabela com o que o Meta gastou por anúncio. Nada de casar com
-- lead, nada de CPL. Só o número como ele é lá.
--
-- Serve para conferir contra o gerenciador e para decidir, depois, como
-- espelhar as UTMs.
-- =====================================================================

set search_path = dash, public;

create or replace function public.gasto_meta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb; v_total numeric; v_de date; v_ate date;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  select jsonb_agg(jsonb_build_object(
    'anuncio', anuncio,
    'conjunto', conjunto,
    'campanha', campanha,
    'ad_id', ad_id,
    'gasto', gasto,
    'impressoes', impressoes,
    'cliques', cliques,
    'cpm', case when impressoes > 0 then round(gasto * 1000 / impressoes, 2) end,
    'cpc', case when cliques > 0 then round(gasto / cliques, 2) end,
    'de', primeiro,
    'ate', ultimo
  ) order by gasto desc)
  into v_res
  from (
    select
      a.ad_id,
      coalesce(nullif(btrim(e.nome), ''), a.ad_id) as anuncio,
      coalesce(nullif(btrim(cj.nome), ''), '—') as conjunto,
      coalesce(nullif(btrim(cp.nome), ''), '—') as campanha,
      round(sum(a.gasto), 2) as gasto,
      sum(a.impressoes) as impressoes,
      sum(a.cliques) as cliques,
      min(a.data_ref) as primeiro,
      max(a.data_ref) as ultimo
    from dash.ads_insights a
    left join dash.ads_entidades e  on e.id = a.ad_id
    left join dash.ads_entidades cj on cj.id = e.parent_id
    left join dash.ads_entidades cp on cp.id = cj.parent_id
    where (v_lanc is null or a.lancamento_id = v_lanc)
    group by a.ad_id, e.nome, cj.nome, cp.nome
  ) t;

  select coalesce(round(sum(gasto), 2), 0), min(data_ref), max(data_ref)
  into v_total, v_de, v_ate
  from dash.ads_insights
  where (v_lanc is null or lancamento_id = v_lanc);

  return jsonb_build_object(
    'ok', true,
    'total', v_total,
    'de', v_de, 'ate', v_ate,
    'linhas', coalesce(jsonb_array_length(v_res), 0),
    'anuncios', coalesce(v_res, '[]'::jsonb)
  );
end $$;

revoke all on function public.gasto_meta(jsonb) from public, anon, authenticated;
grant execute on function public.gasto_meta(jsonb) to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
