-- =====================================================================
-- 78 — COLUNAS POR RESPOSTA DO QUIZ
--
-- Hoje a tela de anúncios separa só engenheiro e não engenheiro. Mas a
-- planilha que o cliente usa tem uma coluna por resposta: engenheiro,
-- técnico, estudante, outras — e uma para quem não respondeu.
--
-- Essa leitura é melhor: mostra o perfil que cada criativo atrai, não só
-- se acertou o público principal. Um anúncio que traz muito estudante
-- não é ruim, é outro público — e isso a coluna de engenheiro esconde.
--
-- As colunas saem da PRIMEIRA pergunta do quiz, que é onde a
-- qualificação acontece. Se o quiz mudar, as colunas mudam junto.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. AS OPÇÕES DA PRIMEIRA PERGUNTA
-- ---------------------------------------------------------------------
create or replace function dash.opcoes_primeira_pergunta(p_lanc uuid)
returns table (valor text, label text, engenheiro boolean, ordem int)
language sql stable as $$
  -- só as opções da PRIMEIRA pergunta: o limit sozinho não bastava,
  -- porque o produto cartesiano trazia as opções de todas elas
  with primeira as (
    select opcoes from dash.quiz_perguntas
    where lancamento_id = p_lanc and ativa is not false
    order by ordem
    limit 1
  )
  select
    o->>'valor',
    coalesce(nullif(o->>'label',''), o->>'valor'),
    coalesce((o->>'engenheiro')::boolean, false),
    (ord)::int
  from primeira, jsonb_array_elements(primeira.opcoes) with ordinality as t(o, ord);
$$;

-- ---------------------------------------------------------------------
-- 2. QUAL É A PRIMEIRA PERGUNTA
-- ---------------------------------------------------------------------
create or replace function dash.chave_primeira_pergunta(p_lanc uuid)
returns text language sql stable as $$
  select chave from dash.quiz_perguntas
  where lancamento_id = p_lanc and ativa is not false
  order by ordem limit 1;
$$;

-- ---------------------------------------------------------------------
-- 3. A TELA DE ANÚNCIOS COM AS COLUNAS
-- ---------------------------------------------------------------------
create or replace function public.dash_anuncios(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_res jsonb; v_resumo jsonb;
  v_chave_pergunta text; v_colunas jsonb; v_enunciado text;
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

  v_chave_pergunta := dash.chave_primeira_pergunta(v_lanc);

  select enunciado into v_enunciado from dash.quiz_perguntas
  where lancamento_id = v_lanc and chave = v_chave_pergunta;

  -- as colunas que a tela vai desenhar, na ordem do quiz
  select jsonb_agg(jsonb_build_object(
    'valor', valor, 'label', label, 'engenheiro', engenheiro
  ) order by ordem)
  into v_colunas
  from dash.opcoes_primeira_pergunta(v_lanc);

  with
  leads as (
    select
      i.id as inscricao_id,
      case when ea.id is not null then i.meta_ad_id end as ad_id_real,
      coalesce(nullif(btrim(ea.nome), ''),
               dash.decodificar_url(i.utm_content),
               '(sem anuncio)') as anuncio,
      coalesce(dash.chave_anuncio(ea.nome),
               dash.chave_anuncio(i.utm_content)) as chave,
      coalesce(i.engenheiro, false) as engenheiro,
      coalesce(i.fez_quiz, false) as fez_quiz,
      coalesce(i.comprou, false) as comprou,
      -- a resposta da primeira pergunta, quando existe
      (select r.resposta_valor from dash.quiz_respostas r
       where r.inscricao_id = i.id and r.pergunta_chave = v_chave_pergunta
       limit 1) as resposta
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
      array_agg(distinct ad_id_real) filter (where ad_id_real is not null) as lista_ids,
      -- uma contagem por opção, e uma para quem não respondeu
      (select jsonb_object_agg(
         coalesce(x.resposta, '(sem resposta)'), x.n
       )
       from (
         select l2.resposta, count(*) as n
         from leads l2
         where coalesce(l2.chave, 'sem-' || l2.anuncio)
               = coalesce(leads.chave, 'sem-' || leads.anuncio)
         group by l2.resposta
       ) x
      ) as por_resposta
    from leads
    group by coalesce(chave, 'sem-' || anuncio), chave, anuncio
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
    select dash.chave_anuncio(e.nome) as chave, a.ad_id,
           round(sum(a.gasto), 2) as gasto,
           sum(a.impressoes) as impressoes, sum(a.cliques) as cliques
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
    'sem_quiz', ag.leads - ag.quiz,
    'respostas', coalesce(ag.por_resposta, '{}'::jsonb),
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
    'sem_quiz', (select count(*) from dash.inscricoes
                 where lancamento_id = v_lanc and not coalesce(fez_quiz, false)),
    -- o total de cada resposta, para os cartões do topo: os mesmos
    -- números das colunas, somados em todos os criativos
    'por_resposta', (
      select coalesce(jsonb_object_agg(resposta, n), '{}'::jsonb)
      from (
        select coalesce(r.resposta_valor, '(sem resposta)') as resposta, count(*) as n
        from dash.inscricoes i
        left join dash.quiz_respostas r
          on r.inscricao_id = i.id and r.pergunta_chave = v_chave_pergunta
        where i.lancamento_id = v_lanc
        group by 1
      ) t
    ),
    'compradores', (select count(*) from dash.inscricoes
                    where lancamento_id = v_lanc and comprou),
    'investido', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights
                  where lancamento_id = v_lanc),
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

  return jsonb_build_object(
    'ok', true,
    'resumo', v_resumo,
    -- a tela desenha uma coluna para cada uma destas, mais a de quem
    -- não respondeu
    'colunas_quiz', coalesce(v_colunas, '[]'::jsonb),
    'pergunta', v_enunciado,
    'anuncios', coalesce(v_res, '[]'::jsonb)
  );
end $$;

grant execute on function public.dash_anuncios(jsonb) to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
