-- =====================================================================
-- 24 — CORREÇÕES
--
-- Duas coisas que só apareceram rodando com dados de verdade:
--
--   1. Com investimento zerado, o CPL saía como R$ 0,00 — que parece
--      excelente mas significa "sem dado". Agora fica vazio.
--
--   2. Quiz é por lançamento, então todo lançamento novo nascia sem
--      quiz nenhum. Como as perguntas mudam pouco de um mês para o
--      outro, agora dá para copiar do anterior.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. CPL SEM INVESTIMENTO = SEM DADO
-- ---------------------------------------------------------------------
create or replace function public.dash_captura(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc dash.lancamentos%rowtype;
  v_leads int; v_eng int; v_investido numeric;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select * into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc.id is null then
    select * into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc.id is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento');
  end if;

  select count(*), count(*) filter (where engenheiro)
  into v_leads, v_eng
  from dash.inscricoes where lancamento_id = v_lanc.id;

  select coalesce(sum(gasto), 0) into v_investido
  from dash.ads_insights where lancamento_id = v_lanc.id;

  return jsonb_build_object(
    'ok', true,
    'lancamento', v_lanc.slug,
    'nome', v_lanc.nome,
    'status', v_lanc.status,
    'leads', v_leads,
    'engenheiros', v_eng,
    'investido', round(v_investido, 2),
    -- sem investimento não existe custo por lead; zero enganaria
    'cpl', case when v_leads > 0 and v_investido > 0
                then round(v_investido / v_leads, 2) end,
    'cpl_engenheiro', case when v_eng > 0 and v_investido > 0
                then round(v_investido / v_eng, 2) end,
    'meta_leads', v_lanc.meta_leads,
    'leads_faltantes', case when v_lanc.meta_leads is not null
                            then greatest(0, v_lanc.meta_leads - v_leads) end,
    'orcamento', v_lanc.investimento_planejado,
    'verba_restante', case when v_lanc.investimento_planejado is not null
                           then greatest(0, v_lanc.investimento_planejado - v_investido) end
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. COPIAR O QUIZ DE OUTRO LANÇAMENTO
--    p: { destino: 'slug-novo', origem: 'slug-antigo' }
--    Sem origem, usa o lançamento anterior mais recente que tenha quiz.
--    Copia as perguntas e a tela de abertura, mas NÃO o link do grupo:
--    esse muda todo mês, e herdar o antigo mandaria os leads novos para
--    o grupo do lançamento passado.
-- ---------------------------------------------------------------------
create or replace function public.copiar_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_dest uuid; v_orig uuid; v_orig_nome text; v_qtd int := 0; v_criado timestamptz;
begin
  select id, criado_em into v_dest, v_criado
  from dash.lancamentos where slug = p->>'destino';
  if v_dest is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento de destino nao encontrado');
  end if;

  if p ? 'origem' and nullif(p->>'origem','') is not null then
    select id, nome into v_orig, v_orig_nome
    from dash.lancamentos where slug = p->>'origem';
  else
    select l.id, l.nome into v_orig, v_orig_nome
    from dash.lancamentos l
    where l.id <> v_dest
      and exists (select 1 from dash.quiz_perguntas q
                  where q.lancamento_id = l.id and q.ativa)
    order by l.criado_em desc limit 1;
  end if;

  if v_orig is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento com quiz para copiar');
  end if;

  insert into dash.quiz_perguntas
    (lancamento_id, chave, enunciado, ordem, peso, opcoes, tipo, obrigatoria, ativa, ajuda, condicao)
  select v_dest, chave, enunciado, ordem, peso, opcoes, tipo, obrigatoria, true, ajuda, condicao
  from dash.quiz_perguntas
  where lancamento_id = v_orig and ativa
  on conflict (lancamento_id, chave) do update set
    enunciado = excluded.enunciado,
    ordem = excluded.ordem,
    opcoes = excluded.opcoes,
    tipo = excluded.tipo,
    obrigatoria = excluded.obrigatoria,
    ativa = true,
    ajuda = excluded.ajuda,
    condicao = excluded.condicao;

  get diagnostics v_qtd = row_count;

  -- leva a tela de abertura junto, mas nunca o link do grupo
  update dash.lancamentos d set
    config = coalesce(d.config,'{}'::jsonb)
             || jsonb_build_object('quiz_intro', o.config->'quiz_intro')
  from dash.lancamentos o
  where d.id = v_dest and o.id = v_orig and o.config ? 'quiz_intro';

  return jsonb_build_object(
    'ok', true, 'perguntas', v_qtd, 'copiado_de', v_orig_nome,
    'aviso', 'O link do grupo nao foi copiado: cadastre o do lancamento novo.'
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. AVISO DE LINK REPETIDO
--    Se dois lançamentos apontarem para o mesmo grupo, os leads novos
--    caem no grupo do lançamento anterior — e tudo continua parecendo
--    funcionar.
-- ---------------------------------------------------------------------
create or replace function public.quiz_admin(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_res jsonb; v_resp int;
  v_grupo text; v_intro jsonb; v_repetido text;
begin
  select id, config->>'grupo_url', config->'quiz_intro'
  into v_lanc, v_grupo, v_intro
  from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select jsonb_agg(jsonb_build_object(
    'chave', chave, 'enunciado', enunciado, 'ordem', ordem, 'tipo', tipo,
    'obrigatoria', obrigatoria, 'ajuda', ajuda, 'opcoes', opcoes, 'condicao', condicao
  ) order by ordem, chave)
  into v_res
  from dash.quiz_perguntas where lancamento_id = v_lanc and ativa;

  select count(*) into v_resp
  from dash.inscricoes where lancamento_id = v_lanc and fez_quiz;

  -- outro lançamento usando o mesmo link?
  if v_grupo is not null then
    select l.nome into v_repetido
    from dash.lancamentos l
    where l.id <> v_lanc and l.config->>'grupo_url' = v_grupo
    limit 1;
  end if;

  return jsonb_build_object(
    'ok', true,
    'perguntas', coalesce(v_res, '[]'::jsonb),
    'ja_responderam', v_resp,
    'grupo_url', v_grupo,
    'intro', v_intro,
    'grupo_repetido', v_repetido,
    'tem_quiz_para_copiar', exists (
      select 1 from dash.quiz_perguntas q
      where q.lancamento_id <> v_lanc and q.ativa
    )
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.copiar_quiz(jsonb) from public, anon, authenticated;
grant execute on function public.copiar_quiz(jsonb), public.dash_captura(jsonb),
  public.quiz_admin(jsonb) to service_role;
