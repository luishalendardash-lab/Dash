-- =====================================================================
-- 12 — QUIZ
--
-- Fluxo: captura -> quiz -> grupo de WhatsApp.
-- As perguntas são por lançamento e montadas pelo admin.
-- "Engenheiro" é marcado pela opção escolhida, não por faixa de score:
-- assim a regra fica visível na tela em vez de escondida num número.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. PERGUNTAS
-- ---------------------------------------------------------------------
alter table dash.quiz_perguntas
  add column if not exists tipo text not null default 'unica',
  add column if not exists obrigatoria boolean not null default true,
  add column if not exists ativa boolean not null default true,
  add column if not exists ajuda text;

-- opcoes: [{ "valor":"sim", "label":"Sou engenheiro", "pontos":40, "engenheiro":true }]

-- ---------------------------------------------------------------------
-- 2. CONSTRUTOR — salva o quiz inteiro de uma vez
--    p: { lancamento, perguntas: [ {chave, enunciado, ordem, tipo,
--         obrigatoria, ajuda, opcoes:[...]} ] }
-- ---------------------------------------------------------------------
create or replace function public.salvar_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_qtd int := 0; v_chaves text[];
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select array_agg(x->>'chave') into v_chaves
  from jsonb_array_elements(coalesce(p->'perguntas','[]'::jsonb)) x;

  -- desativa (não apaga) o que saiu do quiz: respostas antigas continuam válidas
  update dash.quiz_perguntas set ativa = false
  where lancamento_id = v_lanc
    and (v_chaves is null or chave <> all(v_chaves));

  insert into dash.quiz_perguntas
    (lancamento_id, chave, enunciado, ordem, peso, opcoes, tipo, obrigatoria, ativa, ajuda)
  select
    v_lanc,
    x->>'chave',
    x->>'enunciado',
    coalesce((x->>'ordem')::int, 0),
    1,
    coalesce(x->'opcoes', '[]'::jsonb),
    coalesce(nullif(x->>'tipo',''), 'unica'),
    coalesce((x->>'obrigatoria')::boolean, true),
    true,
    nullif(x->>'ajuda','')
  from jsonb_array_elements(coalesce(p->'perguntas','[]'::jsonb)) x
  on conflict (lancamento_id, chave) do update set
    enunciado = excluded.enunciado,
    ordem = excluded.ordem,
    opcoes = excluded.opcoes,
    tipo = excluded.tipo,
    obrigatoria = excluded.obrigatoria,
    ativa = true,
    ajuda = excluded.ajuda;

  get diagnostics v_qtd = row_count;
  return jsonb_build_object('ok', true, 'perguntas', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 3. QUIZ PÚBLICO — o que a página do lead recebe
--    Sem pontos e sem a marcação de engenheiro: se fossem para o
--    navegador, bastaria abrir o inspetor para saber a resposta "certa".
-- ---------------------------------------------------------------------
create or replace function public.quiz_publico(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_slug text; v_titulo text; v_res jsonb; v_grupo text;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, slug, nome, config->>'grupo_url'
    into v_lanc, v_slug, v_titulo, v_grupo
    from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id, slug, nome, config->>'grupo_url'
    into v_lanc, v_slug, v_titulo, v_grupo
    from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

  select jsonb_agg(jsonb_build_object(
    'chave', q.chave,
    'enunciado', q.enunciado,
    'tipo', q.tipo,
    'obrigatoria', q.obrigatoria,
    'ajuda', q.ajuda,
    'opcoes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'valor', o->>'valor', 'label', o->>'label'
      ) order by ord), '[]'::jsonb)
      from jsonb_array_elements(q.opcoes) with ordinality as t(o, ord)
    )
  ) order by q.ordem, q.chave)
  into v_res
  from dash.quiz_perguntas q
  where q.lancamento_id = v_lanc and q.ativa;

  return jsonb_build_object('ok', true, 'lancamento', v_slug, 'titulo', v_titulo,
                            'tem_grupo', v_grupo is not null,
                            'perguntas', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 4. RESPONDER — grava, pontua e decide se é engenheiro
--    p: { inscricao_id | email | telefone, lancamento, respostas: {chave: valor} }
-- ---------------------------------------------------------------------
create or replace function public.responder_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_insc uuid; v_pessoa uuid;
  v_total numeric := 0; v_eng boolean := false; v_tier text;
  r record; v_valor text; v_opcao jsonb;
begin
  -- resolve o lançamento
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

  -- resolve o lead: pelo id da inscrição ou pelo contato
  if nullif(p->>'inscricao_id','') is not null then
    begin
      select id, pessoa_id into v_insc, v_pessoa
      from dash.inscricoes where id = (p->>'inscricao_id')::uuid and lancamento_id = v_lanc;
    exception when others then v_insc := null;
    end;
  end if;

  if v_insc is null then
    begin
      v_pessoa := dash.upsert_pessoa(p->>'email', p->>'telefone', p->>'nome');
    exception when others then
      return jsonb_build_object('ok', false, 'erro', 'nao identificamos seu cadastro');
    end;
    select id into v_insc from dash.inscricoes
    where pessoa_id = v_pessoa and lancamento_id = v_lanc;
    if v_insc is null then
      insert into dash.inscricoes (lancamento_id, pessoa_id, origem_sistema)
      values (v_lanc, v_pessoa, 'quiz') returning id into v_insc;
    end if;
  end if;

  -- percorre as perguntas ativas e casa com o que veio
  for r in
    select chave, opcoes from dash.quiz_perguntas
    where lancamento_id = v_lanc and ativa
  loop
    v_valor := p->'respostas'->>r.chave;
    if v_valor is null then continue; end if;

    select o into v_opcao
    from jsonb_array_elements(r.opcoes) o
    where o->>'valor' = v_valor
    limit 1;

    insert into dash.quiz_respostas
      (inscricao_id, pergunta_chave, resposta_valor, resposta_label, pontos)
    values (
      v_insc, r.chave, v_valor,
      coalesce(v_opcao->>'label', v_valor),
      coalesce((v_opcao->>'pontos')::numeric, 0)
    )
    on conflict (inscricao_id, pergunta_chave) do update set
      resposta_valor = excluded.resposta_valor,
      resposta_label = excluded.resposta_label,
      pontos = excluded.pontos,
      respondido_em = now();

    v_total := v_total + coalesce((v_opcao->>'pontos')::numeric, 0);
    if coalesce((v_opcao->>'engenheiro')::boolean, false) then v_eng := true; end if;
  end loop;

  v_tier := case when v_total >= 70 then 'A' when v_total >= 40 then 'B' else 'C' end;

  update dash.inscricoes set
    lead_score = round(v_total),
    lead_tier = v_tier,
    engenheiro = v_eng or engenheiro,   -- uma vez marcado, não desmarca
    fez_quiz = true,
    quiz_em = coalesce(quiz_em, now()),
    atualizado_em = now()
  where id = v_insc;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, fonte, payload, dedupe_key)
  select v_lanc, i.pessoa_id, v_insc, 'quiz_respondido', 'quiz',
         jsonb_build_object('score', v_total, 'tier', v_tier, 'engenheiro', v_eng),
         'quiz:' || v_insc::text
  from dash.inscricoes i where i.id = v_insc
  on conflict do nothing;

  update dash.inscricoes set etapa = dash.calcular_etapa(v_insc) where id = v_insc;

  return jsonb_build_object(
    'ok', true, 'inscricao_id', v_insc,
    'score', v_total, 'tier', v_tier, 'engenheiro', v_eng
  );
end $$;

-- ---------------------------------------------------------------------
-- 5. LER O QUIZ NO CONSTRUTOR (com pontos e marcação)
-- ---------------------------------------------------------------------
create or replace function public.quiz_admin(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb; v_resp int;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado'); end if;

  select jsonb_agg(jsonb_build_object(
    'chave', chave, 'enunciado', enunciado, 'ordem', ordem, 'tipo', tipo,
    'obrigatoria', obrigatoria, 'ajuda', ajuda, 'opcoes', opcoes
  ) order by ordem, chave)
  into v_res
  from dash.quiz_perguntas where lancamento_id = v_lanc and ativa;

  select count(*) into v_resp
  from dash.inscricoes where lancamento_id = v_lanc and fez_quiz;

  return jsonb_build_object('ok', true, 'perguntas', coalesce(v_res, '[]'::jsonb),
                            'ja_responderam', v_resp);
end $$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.salvar_quiz(jsonb), public.quiz_publico(jsonb),
  public.responder_quiz(jsonb), public.quiz_admin(jsonb) from public, anon, authenticated;
grant execute on function public.salvar_quiz(jsonb), public.quiz_publico(jsonb),
  public.responder_quiz(jsonb), public.quiz_admin(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 7. QUIZ DE EXEMPLO — edite ou refaça pelo construtor
-- ---------------------------------------------------------------------
select public.salvar_quiz('{
  "lancamento": "lanc-2026-09",
  "perguntas": [
    {
      "chave": "formacao", "ordem": 1,
      "enunciado": "Qual a sua formação?",
      "opcoes": [
        {"valor":"eng_eletrica","label":"Engenheiro eletricista","pontos":40,"engenheiro":true},
        {"valor":"eng_outra","label":"Engenheiro de outra área","pontos":25,"engenheiro":true},
        {"valor":"tecnico","label":"Técnico em eletrotécnica","pontos":20},
        {"valor":"estudante","label":"Estudante de engenharia","pontos":10},
        {"valor":"outra","label":"Outra área","pontos":0}
      ]
    },
    {
      "chave": "atuacao", "ordem": 2,
      "enunciado": "Você já atua com perícia?",
      "opcoes": [
        {"valor":"sim_frequente","label":"Sim, com frequência","pontos":30},
        {"valor":"sim_esporadico","label":"Já fiz alguns laudos","pontos":20},
        {"valor":"nao_quero","label":"Ainda não, mas quero começar","pontos":15},
        {"valor":"curiosidade","label":"Só curiosidade","pontos":0}
      ]
    },
    {
      "chave": "faturamento", "ordem": 3,
      "enunciado": "Quanto você fatura hoje por mês?",
      "opcoes": [
        {"valor":"acima_20k","label":"Acima de R$ 20 mil","pontos":30},
        {"valor":"5_20k","label":"Entre R$ 5 mil e R$ 20 mil","pontos":20},
        {"valor":"ate_5k","label":"Até R$ 5 mil","pontos":10},
        {"valor":"sem_renda","label":"Ainda não tenho renda própria","pontos":0}
      ]
    }
  ]
}'::jsonb);

select public.quiz_publico('{"lancamento":"lanc-2026-09"}'::jsonb);
