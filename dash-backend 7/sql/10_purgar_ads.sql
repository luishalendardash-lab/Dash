-- =====================================================================
-- 10 — PURGA DE ANÚNCIOS FORA DO CÓDIGO
--
-- A primeira sincronização (antes do filtro existir) trouxe a conta
-- inteira. Isso limpa o que sobrou e cria uma rotina que roda a cada
-- sincronização, para o lixo não voltar.
--
-- Regra: só fica no lançamento o que descende de uma campanha cujo nome
-- começa com o código do lançamento.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. PURGA — apaga o que não pertence ao código
--    p: { lancamento: 'slug' }   (sem slug, roda em todos)
-- ---------------------------------------------------------------------
create or replace function public.purgar_ads(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_codigo text;
  v_ins int := 0; v_ent int := 0;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, codigo into v_lanc, v_codigo
    from dash.lancamentos where slug = p->>'lancamento';
    if v_lanc is null then
      return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
    end if;
    if v_codigo is null then
      return jsonb_build_object('ok', false, 'erro', 'lancamento sem codigo definido');
    end if;
  end if;

  -- campanhas que NÃO começam com o código do próprio lançamento
  with campanhas_ok as (
    select a.id
    from dash.ads_entidades a
    join dash.lancamentos l on l.id = a.lancamento_id
    where a.nivel = 'campaign'
      and l.codigo is not null
      and upper(btrim(a.nome)) like upper(l.codigo) || '%'
      and (v_lanc is null or a.lancamento_id = v_lanc)
  ),
  manter as (
    -- campanhas válidas + conjuntos delas + anúncios desses conjuntos
    select id from campanhas_ok
    union
    select aj.id from dash.ads_entidades aj
      join campanhas_ok c on c.id = aj.parent_id
    union
    select an.id from dash.ads_entidades an
      join dash.ads_entidades aj2 on aj2.id = an.parent_id
      join campanhas_ok c2 on c2.id = aj2.parent_id
  ),
  alvo as (
    select a.id from dash.ads_entidades a
    where (v_lanc is null or a.lancamento_id = v_lanc)
      and a.id not in (select id from manter)
  ),
  del_ins as (
    delete from dash.ads_insights i
    where i.ad_id in (select id from alvo)
    returning 1
  )
  select count(*) into v_ins from del_ins;

  -- agora as entidades (insights já saíram, então a FK não bloqueia)
  with campanhas_ok as (
    select a.id
    from dash.ads_entidades a
    join dash.lancamentos l on l.id = a.lancamento_id
    where a.nivel = 'campaign'
      and l.codigo is not null
      and upper(btrim(a.nome)) like upper(l.codigo) || '%'
      and (v_lanc is null or a.lancamento_id = v_lanc)
  ),
  manter as (
    select id from campanhas_ok
    union
    select aj.id from dash.ads_entidades aj
      join campanhas_ok c on c.id = aj.parent_id
    union
    select an.id from dash.ads_entidades an
      join dash.ads_entidades aj2 on aj2.id = an.parent_id
      join campanhas_ok c2 on c2.id = aj2.parent_id
  ),
  del_ent as (
    delete from dash.ads_entidades a
    where (v_lanc is null or a.lancamento_id = v_lanc)
      and a.id not in (select id from manter)
    returning 1
  )
  select count(*) into v_ent from del_ent;

  return jsonb_build_object(
    'ok', true,
    'insights_removidos', v_ins,
    'entidades_removidas', v_ent,
    'codigo', v_codigo
  );
end $$;

revoke all on function public.purgar_ads(jsonb) from public, anon, authenticated;
grant execute on function public.purgar_ads(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 2. LIMPEZA AGORA — em todos os lançamentos
-- ---------------------------------------------------------------------
select public.purgar_ads('{}'::jsonb);

-- ---------------------------------------------------------------------
-- 3. CONFERE — deve sobrar só o que tem o código no nome da campanha
-- ---------------------------------------------------------------------
select nivel, count(*) from dash.ads_entidades group by nivel order by nivel;

select l.codigo, a.nome as campanha, count(distinct an.id) as anuncios,
       round(coalesce(sum(i.gasto),0), 2) as gasto
from dash.ads_entidades a
join dash.lancamentos l on l.id = a.lancamento_id
left join dash.ads_entidades aj on aj.parent_id = a.id
left join dash.ads_entidades an on an.parent_id = aj.id
left join dash.ads_insights i on i.ad_id = an.id
where a.nivel = 'campaign'
group by l.codigo, a.nome
order by gasto desc;
