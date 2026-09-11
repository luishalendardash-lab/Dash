-- =====================================================================
-- 94 — PERFIL COMO LISTA DIRETA, USANDO TAMBÉM OS LEADS HISTÓRICOS
--
-- Dois problemas na segmentação anterior:
--
-- 1. Ela só olhava dash.quiz_respostas, que existe para quem respondeu
--    o quiz pela dash. Os leads importados por CSV trazem a marcação de
--    engenheiro na inscrição, mas não uma linha de resposta — então a
--    contagem mostrava três pessoas onde há milhares.
--
-- 2. Escolher a pergunta antes das respostas é um passo a mais sem
--    ganho: a pergunta que interessa é sempre a de qualificação.
--
-- Agora as opções saem da primeira pergunta do quiz, e a contagem junta
-- quem respondeu com quem só tem a marcação de engenheiro.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. QUAL OPÇÃO REPRESENTA O ENGENHEIRO
--    É a que está marcada como engenheiro no quiz.
-- ---------------------------------------------------------------------
create or replace function dash.valor_engenheiro()
returns text language sql stable as $$
  select o->>'valor'
  from dash.quiz_perguntas q,
       jsonb_array_elements(q.opcoes) o
  where coalesce((o->>'engenheiro')::boolean, false)
  order by q.ordem
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- 2. O PERFIL DE CADA LEAD
--
--    A resposta do quiz quando existe; senão, a marcação de engenheiro
--    que veio na importação. Assim o histórico entra na segmentação.
-- ---------------------------------------------------------------------
create or replace function dash.perfil_do_lead(
  p_inscricao uuid, p_engenheiro boolean, p_chave text
) returns text language sql stable as $$
  select coalesce(
    (select r.resposta_valor from dash.quiz_respostas r
     where r.inscricao_id = p_inscricao
       and (p_chave is null or r.pergunta_chave = p_chave)
     limit 1),
    -- sem resposta: só sabemos se era engenheiro
    case when p_engenheiro then dash.valor_engenheiro() end
  );
$$;

-- ---------------------------------------------------------------------
-- 3. AS OPÇÕES DA TELA
--    Só a lista de respostas, sem escolher pergunta.
-- ---------------------------------------------------------------------
create or replace function public.opcoes_segmentacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_slugs text[]; v_chave text; v_opcoes jsonb; v_produtos jsonb;
  v_eng text; v_com_quiz int; v_so_flag int;
begin
  if jsonb_typeof(p->'lancamentos') = 'array'
     and jsonb_array_length(p->'lancamentos') > 0 then
    select array_agg(v) into v_slugs
    from jsonb_array_elements_text(p->'lancamentos') v;
  end if;

  -- a primeira pergunta do quiz é a de qualificação
  select chave into v_chave
  from dash.quiz_perguntas
  where ativa is not false
  order by ordem
  limit 1;

  v_eng := dash.valor_engenheiro();

  -- quantos leads têm resposta de verdade e quantos só a marcação
  select
    count(*) filter (where exists (
      select 1 from dash.quiz_respostas r where r.inscricao_id = i.id)),
    count(*) filter (where not exists (
      select 1 from dash.quiz_respostas r where r.inscricao_id = i.id)
      and coalesce(i.engenheiro, false))
  into v_com_quiz, v_so_flag
  from dash.inscricoes i
  join dash.lancamentos l on l.id = i.lancamento_id
  where (v_slugs is null or l.slug = any(v_slugs));

  -- as opções vêm do quiz; a contagem usa o perfil resolvido
  with opcoes as (
    select distinct on (o->>'valor')
      o->>'valor' as valor,
      coalesce(nullif(o->>'label',''), o->>'valor') as label,
      coalesce((o->>'engenheiro')::boolean, false) as eh_eng,
      (row_number() over ())::int as ordem
    from dash.quiz_perguntas q,
         jsonb_array_elements(q.opcoes) o
    where q.chave = v_chave
  ),
  perfis as (
    select dash.perfil_do_lead(i.id, coalesce(i.engenheiro, false), v_chave) as perfil,
           count(*) as n
    from dash.inscricoes i
    join dash.lancamentos l on l.id = i.lancamento_id
    where (v_slugs is null or l.slug = any(v_slugs))
    group by 1
  )
  select jsonb_agg(jsonb_build_object(
    'valor', o.valor, 'label', o.label, 'engenheiro', o.eh_eng,
    'leads', coalesce(pf.n, 0)
  ) order by o.ordem)
  into v_opcoes
  from opcoes o
  left join perfis pf on pf.perfil = o.valor;

  select jsonb_agg(jsonb_build_object('produto', produto, 'compradores', n)
           order by n desc)
  into v_produtos
  from (
    select coalesce(nullif(btrim(v.produto), ''), '(sem nome)') as produto,
           count(distinct v.pessoa_id) as n
    from dash.vendas v
    where v.status = 'aprovada'
    group by 1
    limit 40
  ) t;

  return jsonb_build_object(
    'ok', true,
    'pergunta_chave', v_chave,
    'opcoes', coalesce(v_opcoes, '[]'::jsonb),
    'produtos', coalesce(v_produtos, '[]'::jsonb),
    -- para a tela avisar quando o histórico não tem quiz
    'com_resposta_quiz', v_com_quiz,
    'so_marcacao_engenheiro', v_so_flag,
    'sem_perfil', (
      select count(*) from dash.inscricoes i
      join dash.lancamentos l on l.id = i.lancamento_id
      where (v_slugs is null or l.slug = any(v_slugs))
        and dash.perfil_do_lead(i.id, coalesce(i.engenheiro, false), v_chave) is null)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. O FILTRO USA O PERFIL RESOLVIDO
-- ---------------------------------------------------------------------
create or replace function dash.leads_segmentados(p jsonb)
returns table (
  pessoa_id uuid, inscricao_id uuid, nome text, email text, telefone text,
  lancamento text, engenheiro boolean, resposta text, capturado_em timestamptz
) language plpgsql stable as $$
declare
  v_slugs text[]; v_respostas text[]; v_produtos text[];
  v_chave text; v_campanha text; v_atual uuid;
begin
  if jsonb_typeof(p->'lancamentos') = 'array'
     and jsonb_array_length(p->'lancamentos') > 0 then
    select array_agg(v) into v_slugs
    from jsonb_array_elements_text(p->'lancamentos') v;
  end if;

  if jsonb_typeof(p->'respostas') = 'array'
     and jsonb_array_length(p->'respostas') > 0 then
    select array_agg(v) into v_respostas
    from jsonb_array_elements_text(p->'respostas') v;
  end if;

  if jsonb_typeof(p->'excluir_produtos') = 'array'
     and jsonb_array_length(p->'excluir_produtos') > 0 then
    select array_agg(dash.chave_produto(v)) into v_produtos
    from jsonb_array_elements_text(p->'excluir_produtos') v;
  end if;

  select chave into v_chave from dash.quiz_perguntas
  where ativa is not false order by ordem limit 1;

  v_campanha := nullif(btrim(coalesce(p->>'campanha','')), '');

  select id into v_atual from dash.lancamentos
  where status in ('captacao','aquecimento','evento','carrinho')
  order by criado_em desc limit 1;

  return query
  with base as (
    select distinct on (pe.id)
      pe.id as p_id, pe.nome as p_nome, pe.email as p_email,
      pe.telefone as p_fone,
      i.id as i_id, l.nome as l_nome,
      coalesce(i.engenheiro, false) as i_eng,
      i.capturado_em as i_quando,
      dash.perfil_do_lead(i.id, coalesce(i.engenheiro, false), v_chave) as r_valor
    from dash.inscricoes i
    join dash.pessoas pe on pe.id = i.pessoa_id
    join dash.lancamentos l on l.id = i.lancamento_id
    where (v_slugs is null or l.slug = any(v_slugs))
      and pe.email is not null
    order by pe.id, i.capturado_em desc
  )
  select b.p_id, b.i_id, b.p_nome, b.p_email, b.p_fone,
         b.l_nome, b.i_eng, b.r_valor, b.i_quando
  from base b
  where
    (v_respostas is null or b.r_valor = any(v_respostas))

    and (v_produtos is null or not exists (
      select 1 from dash.vendas v
      where v.pessoa_id = b.p_id
        and v.status = 'aprovada'
        and dash.chave_produto(v.produto) = any(v_produtos)))

    and (not coalesce((p->>'excluir_lancamento_atual')::boolean, true)
         or v_atual is null
         or not exists (
           select 1 from dash.inscricoes i2
           where i2.pessoa_id = b.p_id and i2.lancamento_id = v_atual))

    and (v_campanha is null or not exists (
      select 1 from dash.reativacoes rr
      where rr.campanha = v_campanha and rr.pessoa_id = b.p_id));
end $$;

grant execute on function public.opcoes_segmentacao(jsonb) to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 5. DIAGNÓSTICO: o histórico tem resposta de quiz?
-- ---------------------------------------------------------------------
select
  (select count(*) from dash.inscricoes) as leads,
  (select count(distinct inscricao_id) from dash.quiz_respostas) as com_resposta_quiz,
  (select count(*) from dash.inscricoes where engenheiro) as marcados_engenheiro;
