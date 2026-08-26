-- =====================================================================
-- 72 — QUAL ID ESTÁ NO LEAD
--
-- A tela passou a mostrar nome de CONJUNTO no lugar do criativo. Isso
-- indica que o campo meta_ad_id dos leads guarda o id do conjunto, não
-- o do anúncio — provavelmente porque a UTM da landing usava
-- {{adset.id}} onde deveria usar {{ad.id}}, ou porque a planilha trocou
-- as colunas na origem.
--
-- Este arquivo descobre com os dados, não por suposição: compara os ids
-- dos leads com o que o Meta devolveu em cada nível.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O QUE OS IDS DOS LEADS SÃO, DE FATO
-- ---------------------------------------------------------------------
create or replace function public.diagnostico_ids(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid;
begin
  select id into v_lanc from dash.lancamentos
  where slug = coalesce(nullif(p->>'lancamento',''), 'x');
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    order by coalesce(captacao_inicio, criado_em) desc limit 1;
  end if;

  return jsonb_build_object(
    'lancamento', (select nome from dash.lancamentos where id = v_lanc),

    -- para cada campo do lead, em que nível ele casa no Meta
    'meta_ad_id', jsonb_build_object(
      'preenchidos', (select count(*) from dash.inscricoes
                      where lancamento_id = v_lanc and meta_ad_id is not null),
      'casa_como_anuncio', (select count(distinct i.meta_ad_id)
        from dash.inscricoes i join dash.ads_entidades e
          on e.id = i.meta_ad_id and e.nivel = 'ad'
        where i.lancamento_id = v_lanc),
      'casa_como_conjunto', (select count(distinct i.meta_ad_id)
        from dash.inscricoes i join dash.ads_entidades e
          on e.id = i.meta_ad_id and e.nivel = 'adset'
        where i.lancamento_id = v_lanc),
      'casa_como_campanha', (select count(distinct i.meta_ad_id)
        from dash.inscricoes i join dash.ads_entidades e
          on e.id = i.meta_ad_id and e.nivel = 'campaign'
        where i.lancamento_id = v_lanc)
    ),

    'meta_adset_id', jsonb_build_object(
      'preenchidos', (select count(*) from dash.inscricoes
                      where lancamento_id = v_lanc and meta_adset_id is not null),
      'casa_como_anuncio', (select count(distinct i.meta_adset_id)
        from dash.inscricoes i join dash.ads_entidades e
          on e.id = i.meta_adset_id and e.nivel = 'ad'
        where i.lancamento_id = v_lanc),
      'casa_como_conjunto', (select count(distinct i.meta_adset_id)
        from dash.inscricoes i join dash.ads_entidades e
          on e.id = i.meta_adset_id and e.nivel = 'adset'
        where i.lancamento_id = v_lanc)
    ),

    'entidades_no_meta', jsonb_build_object(
      'anuncios', (select count(*) from dash.ads_entidades
                   where lancamento_id = v_lanc and nivel = 'ad'),
      'conjuntos', (select count(*) from dash.ads_entidades
                    where lancamento_id = v_lanc and nivel = 'adset'),
      'campanhas', (select count(*) from dash.ads_entidades
                    where lancamento_id = v_lanc and nivel = 'campaign'),
      'exemplo_anuncio', (select nome from dash.ads_entidades
                          where lancamento_id = v_lanc and nivel = 'ad' limit 1),
      'exemplo_conjunto', (select nome from dash.ads_entidades
                           where lancamento_id = v_lanc and nivel = 'adset' limit 1)
    ),

    'gasto', jsonb_build_object(
      'total', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights
                where lancamento_id = v_lanc),
      'em_anuncios', (select coalesce(round(sum(a.gasto),2),0)
        from dash.ads_insights a join dash.ads_entidades e on e.id = a.ad_id
        where a.lancamento_id = v_lanc and e.nivel = 'ad'),
      'em_campanhas', (select coalesce(round(sum(a.gasto),2),0)
        from dash.ads_insights a join dash.ads_entidades e on e.id = a.ad_id
        where a.lancamento_id = v_lanc and e.nivel = 'campaign')
    )
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. A TELA SÓ USA NOME DE ANÚNCIO
--
-- Se o id do lead aponta para um conjunto, mostrar o nome dele engana:
-- parece criativo e não é. Melhor cair para a UTM, que ao menos traz o
-- nome do anúncio.
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
  leads as (
    select
      i.id as inscricao_id,
      -- só aceita o id quando ele é mesmo de um anúncio
      case when ea.id is not null then i.meta_ad_id end as ad_id_real,
      -- o nome: primeiro o do anúncio no Meta, senão o que veio na UTM
      coalesce(nullif(btrim(ea.nome), ''),
               dash.decodificar_url(i.utm_content),
               '(sem anuncio)') as anuncio,
      coalesce(dash.chave_anuncio(ea.nome),
               dash.chave_anuncio(i.utm_content)) as chave,
      coalesce(i.engenheiro, false) as engenheiro,
      coalesce(i.fez_quiz, false) as fez_quiz,
      coalesce(i.comprou, false) as comprou
    from dash.inscricoes i
    left join dash.ads_entidades ea
      on ea.id = i.meta_ad_id and ea.nivel = 'ad'
    where i.lancamento_id = v_lanc
  ),
  agrupado as (
    select
      coalesce(chave, 'sem-' || anuncio) as chave,
      min(anuncio) as anuncio,
      count(*) as leads,
      count(*) filter (where engenheiro) as engenheiros,
      count(*) filter (where fez_quiz) as quiz,
      count(*) filter (where comprou) as compradores,
      count(distinct ad_id_real) as ids,
      array_agg(distinct ad_id_real) filter (where ad_id_real is not null) as lista_ids
    from leads
    group by coalesce(chave, 'sem-' || anuncio)
  ),
  receita as (
    select coalesce(l.chave, 'sem-' || l.anuncio) as chave,
           round(sum(v.valor_bruto), 2) as receita, count(*) as vendas
    from dash.vendas v
    join leads l on l.inscricao_id = v.inscricao_id
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
    group by 1
  ),
  gasto as (
    select
      dash.chave_anuncio(e.nome) as chave,
      a.ad_id,
      round(sum(a.gasto), 2) as gasto,
      sum(a.impressoes) as impressoes,
      sum(a.cliques) as cliques
    from dash.ads_insights a
    join dash.ads_entidades e on e.id = a.ad_id and e.nivel = 'ad'
    where a.lancamento_id = v_lanc
    group by 1, 2
  ),
  casado_id as (
    select ag.chave, sum(g.gasto) as gasto,
           sum(g.impressoes) as impressoes, sum(g.cliques) as cliques
    from agrupado ag
    join gasto g on g.ad_id = any(coalesce(ag.lista_ids, array[]::text[]))
    group by ag.chave
  ),
  casado_nome as (
    select ag.chave, sum(g.gasto) as gasto,
           sum(g.impressoes) as impressoes, sum(g.cliques) as cliques
    from agrupado ag
    join gasto g on g.chave = ag.chave
    where not exists (select 1 from casado_id c where c.chave = ag.chave)
    group by ag.chave
  ),
  final as (
    select * from casado_id union all select * from casado_nome
  )
  select jsonb_agg(jsonb_build_object(
    'anuncio', ag.anuncio,
    'variacoes', ag.ids,
    'leads', ag.leads,
    'engenheiros', ag.engenheiros,
    'pct_engenheiro', case when ag.leads > 0
      then round(100.0 * ag.engenheiros / ag.leads, 1) end,
    'quiz', ag.quiz,
    'compradores', ag.compradores,
    'vendas', coalesce(r.vendas, 0),
    'receita', coalesce(r.receita, 0),
    'gasto', f.gasto,
    'impressoes', f.impressoes,
    'cliques', f.cliques,
    'cpl', case when f.gasto > 0 and ag.leads > 0
      then round(f.gasto / ag.leads, 2) end,
    'cpl_engenheiro', case when f.gasto > 0 and ag.engenheiros > 0
      then round(f.gasto / ag.engenheiros, 2) end,
    'cpa', case when f.gasto > 0 and ag.compradores > 0
      then round(f.gasto / ag.compradores, 2) end,
    'roas', case when f.gasto > 0 and coalesce(r.receita,0) > 0
      then round(r.receita / f.gasto, 2) end,
    'taxa_compra', case when ag.leads > 0
      then round(100.0 * ag.compradores / ag.leads, 2) end,
    'tem_gasto', f.gasto is not null
  ) order by ag.leads desc)
  into v_res
  from agrupado ag
  left join receita r on r.chave = ag.chave
  left join final f on f.chave = ag.chave;

  select jsonb_build_object(
    'leads', (select count(*) from dash.inscricoes where lancamento_id = v_lanc),
    'engenheiros', (select count(*) from dash.inscricoes
                    where lancamento_id = v_lanc and engenheiro),
    'compradores', (select count(*) from dash.inscricoes
                    where lancamento_id = v_lanc and comprou),
    'investido', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights
                  where lancamento_id = v_lanc),
    'investido_em_anuncios', (
      select coalesce(round(sum(a.gasto),2),0)
      from dash.ads_insights a join dash.ads_entidades e on e.id = a.ad_id
      where a.lancamento_id = v_lanc and e.nivel = 'ad'),
    'receita', (select coalesce(round(sum(valor_bruto),2),0) from dash.vendas
                where lancamento_id = v_lanc and status = 'aprovada'),
    'criativos', (select count(*) from (
                   select 1 from dash.inscricoes i
                   left join dash.ads_entidades e on e.id = i.meta_ad_id and e.nivel = 'ad'
                   where i.lancamento_id = v_lanc
                   group by coalesce(dash.chave_anuncio(e.nome),
                                     dash.chave_anuncio(i.utm_content), 'x')) t),
    'com_origem', (select count(*) from dash.inscricoes
                   where lancamento_id = v_lanc
                     and (meta_ad_id is not null or utm_content is not null)),
    'tem_gasto', exists (select 1 from dash.ads_insights where lancamento_id = v_lanc)
  ) into v_resumo;

  return jsonb_build_object('ok', true, 'resumo', v_resumo,
                            'anuncios', coalesce(v_res, '[]'::jsonb));
end $$;

grant execute on function public.dash_anuncios(jsonb), public.diagnostico_ids(jsonb)
  to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 3. RODE E ME MANDE
-- ---------------------------------------------------------------------
select jsonb_pretty(public.diagnostico_ids('{"lancamento":"fpee-2025-09"}'::jsonb));
