-- =====================================================================
-- 70 — CASAR PELO NOME DO ANÚNCIO
--
-- A UTM da landing traz {{ad.name}}, então o que chega no lead é o nome
-- do anúncio como está no gerenciador. O gasto, quando puxado em nível
-- de anúncio, traz o mesmo ad_name. Os dois deveriam bater.
--
-- Não batem por detalhes de escrita:
--   %5BADS10%5D   contra   [ADS10]        escape de URL
--   ADS01 — Cópia contra   ADS01          sufixo de duplicação
--   [ADS05]       contra   [ads05]        caixa
--   ADS 01        contra   ADS01          espaço
--
-- A normalização abaixo resolve os quatro. Ela é usada dos dois lados,
-- então a comparação passa a ser entre iguais.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. NOME COMPARÁVEL
-- ---------------------------------------------------------------------
create or replace function dash.chave_anuncio(txt text)
returns text language plpgsql immutable as $$
declare v text;
begin
  v := dash.decodificar_url(coalesce(txt, ''));
  if v is null or btrim(v) = '' then return null; end if;

  v := lower(v);

  -- "— Cópia", "- copia 2", "(cópia)": o Meta acrescenta ao duplicar, e
  -- para efeito de desempenho é o mesmo criativo
  v := regexp_replace(v, '\s*[—–-]\s*c[óo]pia(\s*\d+)?', '', 'gi');
  v := regexp_replace(v, '\s*\(\s*c[óo]pia(\s*\d+)?\s*\)', '', 'gi');
  v := regexp_replace(v, '\s*[—–-]\s*copy(\s*\d+)?', '', 'gi');

  -- acento fora, para "captação" bater com "captacao"
  v := translate(v, 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn');

  -- só o que identifica: letras, números e traço
  v := regexp_replace(v, '[^a-z0-9]+', '', 'g');

  return nullif(v, '');
end $$;

-- ---------------------------------------------------------------------
-- 2. A TELA CASA POR ID E, NA FALTA, POR NOME NORMALIZADO
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
      i.meta_ad_id,
      -- o nome que o lead trouxe na UTM, ou o que o Meta devolveu
      coalesce(nullif(btrim(e.nome), ''),
               dash.decodificar_url(i.utm_content),
               nullif(btrim(i.meta_ad_id), ''), '(sem anuncio)') as anuncio,
      coalesce(dash.chave_anuncio(e.nome), dash.chave_anuncio(i.utm_content)) as chave,
      coalesce(i.engenheiro, false) as engenheiro,
      coalesce(i.fez_quiz, false) as fez_quiz,
      coalesce(i.comprou, false) as comprou
    from dash.inscricoes i
    left join dash.ads_entidades e on e.id = i.meta_ad_id
    where i.lancamento_id = v_lanc
  ),
  agrupado as (
    -- agrupa pela chave normalizada: cópias do mesmo criativo viram uma
    -- linha só, que é o que interessa para julgar desempenho
    select
      coalesce(chave, 'sem-' || anuncio) as chave,
      min(anuncio) as anuncio,
      count(*) as leads,
      count(*) filter (where engenheiro) as engenheiros,
      count(*) filter (where fez_quiz) as quiz,
      count(*) filter (where comprou) as compradores,
      count(distinct meta_ad_id) as ids,
      array_agg(distinct meta_ad_id) filter (where meta_ad_id is not null) as lista_ids
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
  -- o gasto, com a mesma chave normalizada
  gasto as (
    select
      coalesce(dash.chave_anuncio(e.nome), 'id-' || a.ad_id) as chave,
      round(sum(a.gasto), 2) as gasto,
      sum(a.impressoes) as impressoes,
      sum(a.cliques) as cliques,
      array_agg(distinct a.ad_id) as ids_gasto
    from dash.ads_insights a
    left join dash.ads_entidades e on e.id = a.ad_id
    where a.lancamento_id = v_lanc
    group by 1
  ),
  -- primeiro tenta pelo id do anúncio, que é exato
  casado_id as (
    select ag.chave, sum(g.gasto) as gasto,
           sum(g.impressoes) as impressoes, sum(g.cliques) as cliques
    from agrupado ag
    join gasto g on exists (
      select 1 from unnest(g.ids_gasto) gid
      where gid = any(coalesce(ag.lista_ids, array[]::text[]))
    )
    group by ag.chave
  ),
  -- e só depois pelo nome normalizado
  casado_nome as (
    select ag.chave, sum(g.gasto) as gasto,
           sum(g.impressoes) as impressoes, sum(g.cliques) as cliques
    from agrupado ag
    join gasto g on g.chave = ag.chave
    where not exists (select 1 from casado_id c where c.chave = ag.chave)
    group by ag.chave
  ),
  final as (
    select * from casado_id
    union all
    select * from casado_nome
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
    'receita', (select coalesce(round(sum(valor_bruto),2),0) from dash.vendas
                where lancamento_id = v_lanc and status = 'aprovada'),
    'criativos', (select count(distinct coalesce(
                    dash.chave_anuncio(e.nome), dash.chave_anuncio(i.utm_content), 'x'))
                  from dash.inscricoes i
                  left join dash.ads_entidades e on e.id = i.meta_ad_id
                  where i.lancamento_id = v_lanc),
    'com_origem', (select count(*) from dash.inscricoes
                   where lancamento_id = v_lanc
                     and (meta_ad_id is not null or utm_content is not null)),
    'tem_gasto', exists (select 1 from dash.ads_insights where lancamento_id = v_lanc)
  ) into v_resumo;

  return jsonb_build_object('ok', true, 'resumo', v_resumo,
                            'anuncios', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 3. QUEM NÃO CASOU
--    Mostra os nomes dos dois lados que ficaram sem par, para você ver
--    se é problema de nomenclatura na campanha.
-- ---------------------------------------------------------------------
create or replace function public.nomes_sem_par(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_leads jsonb; v_gasto jsonb;
begin
  select id into v_lanc from dash.lancamentos
  where slug = coalesce(nullif(p->>'lancamento',''), 'x');
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    order by coalesce(captacao_inicio, criado_em) desc limit 1;
  end if;

  -- criativos com lead e sem gasto
  select jsonb_agg(jsonb_build_object('nome', nome, 'leads', n) order by n desc)
  into v_leads
  from (
    select dash.decodificar_url(i.utm_content) as nome, count(*) as n
    from dash.inscricoes i
    where i.lancamento_id = v_lanc and i.utm_content is not null
      and not exists (
        select 1 from dash.ads_insights a
        left join dash.ads_entidades e on e.id = a.ad_id
        where a.lancamento_id = v_lanc
          and (a.ad_id = i.meta_ad_id
               or dash.chave_anuncio(e.nome) = dash.chave_anuncio(i.utm_content))
      )
    group by 1 order by count(*) desc limit 15
  ) t;

  -- gasto sem lead nenhum
  select jsonb_agg(jsonb_build_object('nome', nome, 'gasto', gasto) order by gasto desc)
  into v_gasto
  from (
    select coalesce(e.nome, a.ad_id) as nome, round(sum(a.gasto), 2) as gasto
    from dash.ads_insights a
    left join dash.ads_entidades e on e.id = a.ad_id
    where a.lancamento_id = v_lanc
      and not exists (
        select 1 from dash.inscricoes i
        where i.lancamento_id = v_lanc
          and (i.meta_ad_id = a.ad_id
               or dash.chave_anuncio(i.utm_content) = dash.chave_anuncio(e.nome))
      )
    group by 1 order by sum(a.gasto) desc limit 15
  ) t;

  return jsonb_build_object(
    'ok', true,
    'com_lead_sem_gasto', coalesce(v_leads, '[]'::jsonb),
    'com_gasto_sem_lead', coalesce(v_gasto, '[]'::jsonb)
  );
end $$;

grant execute on function public.dash_anuncios(jsonb), public.nomes_sem_par(jsonb)
  to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 4. TESTE DA NORMALIZAÇÃO
-- ---------------------------------------------------------------------
select
  dash.chave_anuncio('%5BADS10%5D')       as escape_url,
  dash.chave_anuncio('[ADS10] — Cópia')   as com_copia,
  dash.chave_anuncio('[ads10]')           as minusculo,
  dash.chave_anuncio('ADS 10')            as com_espaco,
  dash.chave_anuncio('[ADS10] — Cópia 2') as copia_numerada;
