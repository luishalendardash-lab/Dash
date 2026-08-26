-- =====================================================================
-- 68 — LIGAR O GASTO AO CRIATIVO
--
-- O investimento aparece no total mas não por criativo. O motivo é que
-- os dois lados estão sendo comparados pelo NOME, e os nomes não são os
-- mesmos: o lead guarda o que veio na UTM, o gasto guarda o que o Meta
-- devolve. Basta uma cópia, um acento ou um espaço para não casar.
--
-- A ligação certa é pelo ID do anúncio, que é igual dos dois lados. O
-- nome vira reserva, para quando o ID não existe.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. DIAGNÓSTICO — rode e veja onde está o desencontro
-- ---------------------------------------------------------------------
create or replace function public.diagnostico_gasto(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb;
begin
  select id into v_lanc from dash.lancamentos
  where slug = coalesce(nullif(p->>'lancamento',''), 'x');
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    order by coalesce(captacao_inicio, criado_em) desc limit 1;
  end if;

  select jsonb_build_object(
    'lancamento', (select nome from dash.lancamentos where id = v_lanc),

    'leads', jsonb_build_object(
      'total', (select count(*) from dash.inscricoes where lancamento_id = v_lanc),
      'com_id_do_anuncio', (select count(*) from dash.inscricoes
        where lancamento_id = v_lanc and meta_ad_id is not null),
      'com_nome_do_criativo', (select count(*) from dash.inscricoes
        where lancamento_id = v_lanc and utm_content is not null),
      'exemplos_de_id', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select distinct meta_ad_id as x from dash.inscricoes
        where lancamento_id = v_lanc and meta_ad_id is not null limit 3) t),
      'exemplos_de_nome', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select distinct utm_content as x from dash.inscricoes
        where lancamento_id = v_lanc and utm_content is not null limit 3) t)
    ),

    'gasto', jsonb_build_object(
      'registros', (select count(*) from dash.ads_insights where lancamento_id = v_lanc),
      'total', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights
                where lancamento_id = v_lanc),
      'exemplos_de_id', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select distinct ad_id as x from dash.ads_insights
        where lancamento_id = v_lanc limit 3) t),
      'exemplos_de_nome', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select distinct e.nome as x from dash.ads_insights a
        join dash.ads_entidades e on e.id = a.ad_id
        where a.lancamento_id = v_lanc limit 3) t)
    ),

    -- o número que importa: quantos IDs existem nos dois lados
    'casam_por_id', (
      select count(distinct i.meta_ad_id)
      from dash.inscricoes i
      join dash.ads_insights a on a.ad_id = i.meta_ad_id
      where i.lancamento_id = v_lanc
    ),
    'casam_por_nome', (
      select count(distinct i.utm_content)
      from dash.inscricoes i
      join dash.ads_entidades e on btrim(lower(e.nome)) = btrim(lower(i.utm_content))
      join dash.ads_insights a on a.ad_id = e.id
      where i.lancamento_id = v_lanc
    )
  ) into v_res;

  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 2. A TELA PASSA A CASAR PELO ID
-- ---------------------------------------------------------------------
create or replace function public.dash_anuncios(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb; v_resumo jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento');
  end if;

  with
  -- ---- cada lead com sua chave de agrupamento
  leads as (
    select
      i.id as inscricao_id,
      i.meta_ad_id,
      -- o nome exibido: preferimos o que o Meta devolveu, porque é o que
      -- aparece no gerenciador; a UTM é reserva
      coalesce(nullif(btrim(e.nome), ''), nullif(btrim(i.utm_content), ''),
               nullif(btrim(i.meta_ad_id), ''), '(sem anuncio)') as anuncio,
      coalesce(i.engenheiro, false) as engenheiro,
      coalesce(i.fez_quiz, false) as fez_quiz,
      coalesce(i.comprou, false) as comprou
    from dash.inscricoes i
    left join dash.ads_entidades e on e.id = i.meta_ad_id
    where i.lancamento_id = v_lanc
  ),
  por_nome as (
    select anuncio,
           count(*) as leads,
           count(*) filter (where engenheiro) as engenheiros,
           count(*) filter (where fez_quiz) as quiz,
           count(*) filter (where comprou) as compradores,
           count(distinct meta_ad_id) as ids,
           array_agg(distinct meta_ad_id) filter (where meta_ad_id is not null) as lista_ids
    from leads group by anuncio
  ),
  receita as (
    select l.anuncio, round(sum(v.valor_bruto), 2) as receita, count(*) as vendas
    from dash.vendas v
    join leads l on l.inscricao_id = v.inscricao_id
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
    group by l.anuncio
  ),
  -- ---- o gasto, ligado pelo ID do anúncio
  --
  -- Primeiro tenta pelo id: é igual dos dois lados e não sofre com
  -- cópia, acento ou espaço no nome. Só depois cai para o nome.
  gasto_por_id as (
    select pn.anuncio,
           round(sum(a.gasto), 2) as gasto,
           sum(a.impressoes) as impressoes,
           sum(a.cliques) as cliques
    from por_nome pn
    join dash.ads_insights a on a.ad_id = any(pn.lista_ids)
    where a.lancamento_id = v_lanc
    group by pn.anuncio
  ),
  gasto_por_nome as (
    select pn.anuncio,
           round(sum(a.gasto), 2) as gasto,
           sum(a.impressoes) as impressoes,
           sum(a.cliques) as cliques
    from por_nome pn
    join dash.ads_entidades e
      on btrim(lower(e.nome)) = btrim(lower(pn.anuncio))
    join dash.ads_insights a on a.ad_id = e.id
    where a.lancamento_id = v_lanc
      and not exists (select 1 from gasto_por_id g where g.anuncio = pn.anuncio)
    group by pn.anuncio
  ),
  gasto as (
    select * from gasto_por_id
    union all
    select * from gasto_por_nome
  )
  select jsonb_agg(jsonb_build_object(
    'anuncio', pn.anuncio,
    'variacoes', pn.ids,
    'leads', pn.leads,
    'engenheiros', pn.engenheiros,
    'pct_engenheiro', case when pn.leads > 0
      then round(100.0 * pn.engenheiros / pn.leads, 1) end,
    'quiz', pn.quiz,
    'compradores', pn.compradores,
    'vendas', coalesce(r.vendas, 0),
    'receita', coalesce(r.receita, 0),
    'gasto', g.gasto,
    'impressoes', g.impressoes,
    'cliques', g.cliques,
    'cpl', case when g.gasto > 0 and pn.leads > 0
      then round(g.gasto / pn.leads, 2) end,
    'cpl_engenheiro', case when g.gasto > 0 and pn.engenheiros > 0
      then round(g.gasto / pn.engenheiros, 2) end,
    'cpa', case when g.gasto > 0 and pn.compradores > 0
      then round(g.gasto / pn.compradores, 2) end,
    'roas', case when g.gasto > 0 and coalesce(r.receita,0) > 0
      then round(r.receita / g.gasto, 2) end,
    'taxa_compra', case when pn.leads > 0
      then round(100.0 * pn.compradores / pn.leads, 2) end,
    'tem_gasto', g.gasto is not null
  ) order by pn.leads desc)
  into v_res
  from por_nome pn
  left join receita r on r.anuncio = pn.anuncio
  left join gasto g on g.anuncio = pn.anuncio;

  select jsonb_build_object(
    'leads', (select count(*) from dash.inscricoes where lancamento_id = v_lanc),
    'engenheiros', (select count(*) from dash.inscricoes
                    where lancamento_id = v_lanc and engenheiro),
    'compradores', (select count(*) from dash.inscricoes
                    where lancamento_id = v_lanc and comprou),
    'investido', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights
                  where lancamento_id = v_lanc),
    -- quanto do gasto a tela conseguiu ligar a um criativo: se for muito
    -- menor que o investido, a atribuição está incompleta e é melhor
    -- saber disso do que confiar num CPL pela metade
    'investido_atribuido', (
      select coalesce(round(sum(a.gasto),2),0)
      from dash.ads_insights a
      where a.lancamento_id = v_lanc
        and (exists (select 1 from dash.inscricoes i
                     where i.lancamento_id = v_lanc and i.meta_ad_id = a.ad_id)
             or exists (select 1 from dash.ads_entidades e
                        join dash.inscricoes i2 on btrim(lower(i2.utm_content)) = btrim(lower(e.nome))
                        where e.id = a.ad_id and i2.lancamento_id = v_lanc))
    ),
    'receita', (select coalesce(round(sum(valor_bruto),2),0) from dash.vendas
                where lancamento_id = v_lanc and status = 'aprovada'),
    'criativos', (select count(*) from (
                   select 1 from dash.inscricoes i
                   left join dash.ads_entidades a on a.id = i.meta_ad_id
                   where i.lancamento_id = v_lanc
                   group by coalesce(nullif(btrim(a.nome),''),
                                     nullif(btrim(i.utm_content),''), 'x')) t),
    'com_origem', (select count(*) from dash.inscricoes
                   where lancamento_id = v_lanc
                     and (meta_ad_id is not null or utm_content is not null)),
    'tem_gasto', exists (select 1 from dash.ads_insights where lancamento_id = v_lanc)
  ) into v_resumo;

  return jsonb_build_object('ok', true, 'resumo', v_resumo,
                            'anuncios', coalesce(v_res, '[]'::jsonb));
end $$;

grant execute on function public.dash_anuncios(jsonb), public.diagnostico_gasto(jsonb)
  to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 3. RODE ISTO E ME MANDE
-- ---------------------------------------------------------------------
select jsonb_pretty(public.diagnostico_gasto('{"lancamento":"fpee-2025-09"}'::jsonb));
