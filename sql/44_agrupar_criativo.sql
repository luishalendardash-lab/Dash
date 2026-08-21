-- =====================================================================
-- 44 — AGRUPAR CRIATIVO POR NOME
--
-- O Meta cria um ID novo a cada cópia de anúncio, então "ADS01 — Cópia"
-- aparece em várias linhas com IDs diferentes. Isso quebra a leitura:
-- um criativo com 800 leads no total aparece como três de 300, 250 e 250,
-- e some do topo da lista.
--
-- Agora a tela agrupa pelo NOME, somando os IDs. O ID continua guardado
-- para buscar o gasto no Meta — só a exibição muda.
-- =====================================================================

set search_path = dash, public;

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

  with leads as (
    select
      i.id as inscricao_id,
      i.meta_ad_id,
      -- agrupa pelo nome; o ID vira detalhe, não chave
      coalesce(nullif(btrim(a.nome), ''), nullif(btrim(i.utm_content), ''),
               nullif(btrim(i.meta_ad_id), ''), '(sem anuncio)') as anuncio,
      coalesce(ac.nome, nullif(btrim(i.utm_campaign), ''), '(sem campanha)') as campanha,
      coalesce(i.engenheiro, false) as engenheiro,
      coalesce(i.fez_quiz, false) as fez_quiz,
      coalesce(i.comprou, false) as comprou
    from dash.inscricoes i
    left join dash.ads_entidades a  on a.id = i.meta_ad_id
    left join dash.ads_entidades aj on aj.id = a.parent_id
    left join dash.ads_entidades ac on ac.id = aj.parent_id
    where i.lancamento_id = v_lanc
  ),
  por_nome as (
    -- o mesmo criativo roda em várias campanhas; contamos quantas em vez
    -- de mostrar uma só, que daria a impressão errada de exclusividade
    select anuncio,
           count(distinct campanha) as campanhas,
           count(*) as leads,
           count(*) filter (where engenheiro) as engenheiros,
           count(*) filter (where fez_quiz) as quiz,
           count(*) filter (where comprou) as compradores,
           count(distinct meta_ad_id) as ids
    from leads group by anuncio
  ),
  receita as (
    select l.anuncio, round(sum(v.valor_bruto), 2) as receita, count(*) as vendas
    from dash.vendas v
    join leads l on l.inscricao_id = v.inscricao_id
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
    group by l.anuncio
  ),
  -- soma o gasto de todos os IDs que compartilham o mesmo nome
  gasto as (
    select coalesce(nullif(btrim(e.nome), ''), ins.ad_id) as anuncio,
           round(sum(ins.gasto), 2) as gasto,
           sum(ins.impressoes) as impressoes,
           sum(ins.cliques) as cliques
    from dash.ads_insights ins
    left join dash.ads_entidades e on e.id = ins.ad_id
    where ins.lancamento_id = v_lanc
    group by coalesce(nullif(btrim(e.nome), ''), ins.ad_id)
  )
  select jsonb_agg(jsonb_build_object(
    'anuncio', pn.anuncio,
    'campanhas', pn.campanhas,
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

grant execute on function public.dash_anuncios(jsonb) to service_role;

select 'pronto' as status;
