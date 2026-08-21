-- =====================================================================
-- 37 — DESEMPENHO POR CRIATIVO
--
-- A pergunta que essa tela responde, por criativo:
--   quantos leads trouxe
--   quantos eram engenheiros
--   quanto custou cada lead e cada engenheiro
--   quantos compraram e qual o custo por venda
--
-- Duas fontes se juntam aqui:
--   os LEADS, que sabem de qual anúncio vieram (pelo id do Meta ou pelo
--   nome que veio na UTM)
--   os INSIGHTS do Meta, que sabem quanto foi gasto
--
-- Quando o gasto não existe — lançamento antigo que nunca foi
-- sincronizado — a tela mostra leads e engenheiros mesmo assim, com os
-- custos vazios. Melhor um quadro incompleto e honesto do que nenhum.
-- =====================================================================

set search_path = dash, public;

create index if not exists ix_insc_ad on dash.inscricoes (lancamento_id, meta_ad_id);
create index if not exists ix_insc_content on dash.inscricoes (lancamento_id, utm_content);

-- ---------------------------------------------------------------------
-- DESEMPENHO POR CRIATIVO
-- ---------------------------------------------------------------------
create or replace function public.dash_anuncios(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_res jsonb; v_resumo jsonb;
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
  -- ---- o que cada lead trouxe
  leads as (
    select
      i.id as inscricao_id,
      -- a chave do criativo: o id do Meta quando existe, senão o nome
      coalesce(nullif(btrim(i.meta_ad_id), ''),
               nullif(btrim(i.utm_content), ''),
               '(sem anuncio)') as chave,
      coalesce(a.nome, nullif(btrim(i.utm_content), ''),
               nullif(btrim(i.meta_ad_id), ''), '(sem anuncio)') as anuncio,
      coalesce(ac.nome, nullif(btrim(i.utm_campaign), ''), '(sem campanha)') as campanha,
      coalesce(aj.nome, nullif(btrim(i.utm_medium), ''), '') as conjunto,
      coalesce(i.engenheiro, false) as engenheiro,
      coalesce(i.fez_quiz, false) as fez_quiz,
      coalesce(i.entrou_grupo, false) as entrou_grupo,
      coalesce(i.comprou, false) as comprou
    from dash.inscricoes i
    left join dash.ads_entidades a  on a.id = i.meta_ad_id
    left join dash.ads_entidades aj on aj.id = a.parent_id
    left join dash.ads_entidades ac on ac.id = aj.parent_id
    where i.lancamento_id = v_lanc
  ),
  por_lead as (
    select chave, min(anuncio) as anuncio, min(campanha) as campanha,
           min(conjunto) as conjunto,
           count(*) as leads,
           count(*) filter (where engenheiro) as engenheiros,
           count(*) filter (where fez_quiz) as quiz,
           count(*) filter (where entrou_grupo) as grupo,
           count(*) filter (where comprou) as compradores
    from leads group by chave
  ),
  -- ---- receita de quem veio de cada criativo
  receita as (
    select l.chave, round(sum(v.valor_bruto), 2) as receita, count(*) as vendas
    from dash.vendas v
    join leads l on l.inscricao_id = v.inscricao_id
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
    group by l.chave
  ),
  -- ---- gasto do Meta, quando existe
  gasto as (
    select ins.ad_id as chave,
           round(sum(ins.gasto), 2) as gasto,
           sum(ins.impressoes) as impressoes,
           sum(ins.cliques) as cliques,
           sum(coalesce(ins.cliques_link, 0)) as cliques_link,
           sum(coalesce(ins.resultados, 0)) as resultados_meta
    from dash.ads_insights ins
    where ins.lancamento_id = v_lanc
    group by ins.ad_id
  )
  select
    jsonb_agg(jsonb_build_object(
      'chave', pl.chave,
      'anuncio', pl.anuncio,
      'campanha', pl.campanha,
      'conjunto', nullif(pl.conjunto, ''),
      'leads', pl.leads,
      'engenheiros', pl.engenheiros,
      'pct_engenheiro', case when pl.leads > 0
        then round(100.0 * pl.engenheiros / pl.leads, 1) end,
      'quiz', pl.quiz,
      'grupo', pl.grupo,
      'compradores', pl.compradores,
      'vendas', coalesce(r.vendas, 0),
      'receita', coalesce(r.receita, 0),
      'gasto', g.gasto,
      'impressoes', g.impressoes,
      'cliques', g.cliques,
      -- os números que decidem onde colocar verba
      'cpl', case when g.gasto > 0 and pl.leads > 0
        then round(g.gasto / pl.leads, 2) end,
      'cpl_engenheiro', case when g.gasto > 0 and pl.engenheiros > 0
        then round(g.gasto / pl.engenheiros, 2) end,
      'cpa', case when g.gasto > 0 and pl.compradores > 0
        then round(g.gasto / pl.compradores, 2) end,
      'roas', case when g.gasto > 0 and coalesce(r.receita,0) > 0
        then round(r.receita / g.gasto, 2) end,
      'taxa_compra', case when pl.leads > 0
        then round(100.0 * pl.compradores / pl.leads, 2) end,
      'tem_gasto', g.gasto is not null
    ) order by pl.leads desc)
  into v_res
  from por_lead pl
  left join receita r on r.chave = pl.chave
  left join gasto g on g.chave = pl.chave;

  -- ---- totais do lançamento
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
    'criativos', (select count(distinct coalesce(nullif(btrim(meta_ad_id),''),
                                                 nullif(btrim(utm_content),''), 'x'))
                  from dash.inscricoes where lancamento_id = v_lanc),
    'com_origem', (select count(*) from dash.inscricoes
                   where lancamento_id = v_lanc
                     and (meta_ad_id is not null or utm_content is not null)),
    'tem_gasto', exists (select 1 from dash.ads_insights where lancamento_id = v_lanc)
  ) into v_resumo;

  return jsonb_build_object(
    'ok', true,
    'resumo', v_resumo,
    'anuncios', coalesce(v_res, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- INVESTIMENTO LANÇADO À MÃO
--
-- Para lançamentos antigos: se não der para sincronizar o Meta daquele
-- período, dá para informar o gasto por criativo e ter os custos mesmo
-- assim. Entra como insight normal, então soma no investido do
-- lançamento.
-- ---------------------------------------------------------------------
create or replace function public.lancar_gasto_manual(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_linha jsonb; v_dia date; v_qtd int := 0; v_chave text;
begin
  select id, coalesce(captacao_inicio, criado_em)::date
  into v_lanc, v_dia
  from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  for v_linha in select * from jsonb_array_elements(coalesce(p->'gastos','[]'::jsonb))
  loop
    v_chave := nullif(btrim(v_linha->>'chave'),'');
    continue when v_chave is null;

    -- a entidade precisa existir para o insight ter onde se apoiar
    insert into dash.ads_entidades (id, lancamento_id, nivel, nome, conta_id)
    values (v_chave, v_lanc, 'ad',
            coalesce(nullif(btrim(v_linha->>'anuncio'),''), v_chave), 'manual')
    on conflict (id) do nothing;

    insert into dash.ads_insights
      (ad_id, lancamento_id, data_ref, gasto, impressoes, cliques)
    values (v_chave, v_lanc, v_dia,
            coalesce(dash.valor_para_numero(v_linha->>'gasto'), 0), 0, 0)
    on conflict (ad_id, data_ref) do update set
      gasto = excluded.gasto;

    v_qtd := v_qtd + 1;
  end loop;

  return jsonb_build_object('ok', true, 'criativos', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.lancar_gasto_manual(jsonb) from public, anon, authenticated;
grant execute on function public.dash_anuncios(jsonb), public.lancar_gasto_manual(jsonb)
  to service_role;

select public.dash_anuncios('{}'::jsonb) -> 'ok' as anuncios_ok;
