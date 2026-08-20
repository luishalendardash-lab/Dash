-- =====================================================================
-- 13 — QUIZ: ABERTURA, PERGUNTA ABERTA E CONDICIONAL
--
-- Três adições, todas vistas no fluxo real:
--   1. tela de boas-vindas antes das perguntas
--   2. pergunta de texto livre
--   3. pergunta que só aparece se a resposta anterior for X
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. COLUNAS
-- ---------------------------------------------------------------------
alter table dash.quiz_perguntas
  add column if not exists condicao jsonb;   -- {"chave":"incomoda","valores":["outra"]}

-- respostas de texto livre podem ser longas
alter table dash.quiz_respostas
  alter column resposta_valor type text,
  alter column resposta_label type text;

-- ---------------------------------------------------------------------
-- 2. SALVAR — agora com abertura e condicional
--    p: { lancamento, grupo_url, intro:{titulo,texto,botao}, perguntas:[...] }
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

  update dash.quiz_perguntas set ativa = false
  where lancamento_id = v_lanc
    and (v_chaves is null or chave <> all(v_chaves));

  insert into dash.quiz_perguntas
    (lancamento_id, chave, enunciado, ordem, peso, opcoes, tipo, obrigatoria, ativa, ajuda, condicao)
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
    nullif(x->>'ajuda',''),
    case when x ? 'condicao' and x->'condicao' <> 'null'::jsonb
         then x->'condicao' else null end
  from jsonb_array_elements(coalesce(p->'perguntas','[]'::jsonb)) x
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

  update dash.lancamentos
  set config = coalesce(config,'{}'::jsonb)
    || case when p ? 'grupo_url'
            then jsonb_build_object('grupo_url', nullif(btrim(p->>'grupo_url'), ''))
            else '{}'::jsonb end
    || case when p ? 'intro'
            then jsonb_build_object('quiz_intro', p->'intro')
            else '{}'::jsonb end
  where id = v_lanc;

  return jsonb_build_object('ok', true, 'perguntas', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 3. QUIZ PÚBLICO — devolve abertura, tipo e condição
-- ---------------------------------------------------------------------
create or replace function public.quiz_publico(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_slug text; v_titulo text; v_res jsonb;
        v_grupo text; v_intro jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, slug, nome, config->>'grupo_url', config->'quiz_intro'
    into v_lanc, v_slug, v_titulo, v_grupo, v_intro
    from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id, slug, nome, config->>'grupo_url', config->'quiz_intro'
    into v_lanc, v_slug, v_titulo, v_grupo, v_intro
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
    'condicao', q.condicao,
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
                            'intro', v_intro, 'tem_grupo', v_grupo is not null,
                            'perguntas', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 4. RESPONDER — aceita texto livre
-- ---------------------------------------------------------------------
create or replace function public.responder_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_insc uuid; v_pessoa uuid;
  v_total numeric := 0; v_eng boolean := false; v_tier text;
  r record; v_valor text; v_opcao jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

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

  for r in
    select chave, opcoes, tipo from dash.quiz_perguntas
    where lancamento_id = v_lanc and ativa
  loop
    v_valor := p->'respostas'->>r.chave;
    if v_valor is null or btrim(v_valor) = '' then continue; end if;

    if r.tipo = 'texto' then
      -- texto livre: guarda como veio, sem pontuar
      insert into dash.quiz_respostas
        (inscricao_id, pergunta_chave, resposta_valor, resposta_label, pontos)
      values (v_insc, r.chave, left(btrim(v_valor), 2000), left(btrim(v_valor), 2000), 0)
      on conflict (inscricao_id, pergunta_chave) do update set
        resposta_valor = excluded.resposta_valor,
        resposta_label = excluded.resposta_label,
        respondido_em = now();
      continue;
    end if;

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
    lead_score = round(v_total), lead_tier = v_tier,
    engenheiro = v_eng or engenheiro,
    fez_quiz = true, quiz_em = coalesce(quiz_em, now()), atualizado_em = now()
  where id = v_insc;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, fonte, payload, dedupe_key)
  select v_lanc, i.pessoa_id, v_insc, 'quiz_respondido', 'quiz',
         jsonb_build_object('score', v_total, 'tier', v_tier, 'engenheiro', v_eng),
         'quiz:' || v_insc::text
  from dash.inscricoes i where i.id = v_insc
  on conflict do nothing;

  update dash.inscricoes set etapa = dash.calcular_etapa(v_insc) where id = v_insc;

  return jsonb_build_object('ok', true, 'inscricao_id', v_insc,
                            'score', v_total, 'tier', v_tier, 'engenheiro', v_eng);
end $$;

-- ---------------------------------------------------------------------
-- 5. ADMIN — devolve tudo que o construtor precisa
-- ---------------------------------------------------------------------
create or replace function public.quiz_admin(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb; v_resp int; v_grupo text; v_intro jsonb;
begin
  select id, config->>'grupo_url', config->'quiz_intro'
  into v_lanc, v_grupo, v_intro
  from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado'); end if;

  select jsonb_agg(jsonb_build_object(
    'chave', chave, 'enunciado', enunciado, 'ordem', ordem, 'tipo', tipo,
    'obrigatoria', obrigatoria, 'ajuda', ajuda, 'opcoes', opcoes, 'condicao', condicao
  ) order by ordem, chave)
  into v_res
  from dash.quiz_perguntas where lancamento_id = v_lanc and ativa;

  select count(*) into v_resp
  from dash.inscricoes where lancamento_id = v_lanc and fez_quiz;

  return jsonb_build_object('ok', true, 'perguntas', coalesce(v_res, '[]'::jsonb),
                            'ja_responderam', v_resp, 'grupo_url', v_grupo, 'intro', v_intro);
end $$;

revoke all on function public.salvar_quiz(jsonb), public.quiz_publico(jsonb),
  public.responder_quiz(jsonb), public.quiz_admin(jsonb) from public, anon, authenticated;
grant execute on function public.salvar_quiz(jsonb), public.quiz_publico(jsonb),
  public.responder_quiz(jsonb), public.quiz_admin(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 6. QUIZ DO PERITO — o fluxo real, já montado
-- ---------------------------------------------------------------------
select public.salvar_quiz('{
  "lancamento": "lanc-2026-09",
  "intro": {
    "titulo": "Seja muito bem-vindo(a)!",
    "texto": "Só falta mais esse passo. Para que essa oportunidade única seja o seu passaporte para uma nova realidade dentro da área de laudos da Engenharia Elétrica, preciso confirmar algo importante com você.",
    "botao": "Responder"
  },
  "perguntas": [
    {
      "chave": "formacao", "ordem": 1,
      "enunciado": "Qual é a sua formação na área elétrica?",
      "opcoes": [
        {"valor":"tecnico","label":"Sou técnico ou tecnólogo","pontos":20},
        {"valor":"eng_eletricista","label":"Sou Engenheiro Eletricista","pontos":40,"engenheiro":true},
        {"valor":"faculdade","label":"Ainda estou na faculdade","pontos":10},
        {"valor":"eng_outra","label":"Sou Engenheiro de outra área","pontos":25,"engenheiro":true},
        {"valor":"sem_formacao","label":"Não tenho formação na área elétrica","pontos":0}
      ]
    },
    {
      "chave": "atuacao", "ordem": 2,
      "enunciado": "Você atua ou quer atuar com laudos de engenharia elétrica?",
      "opcoes": [
        {"valor":"quero_comecar","label":"Já ouvi falar sobre a área e quero começar a fazer laudos","pontos":20},
        {"valor":"ja_trabalho","label":"Sim, já trabalho com laudos","pontos":30},
        {"valor":"nao_conheco","label":"Não conheço, mas me interessei","pontos":10},
        {"valor":"estudante","label":"Sou estudante e quero me preparar","pontos":10}
      ]
    },
    {
      "chave": "incomoda", "ordem": 3,
      "enunciado": "Hoje, o que mais te incomoda na sua profissão?",
      "opcoes": [
        {"valor":"pouco_dinheiro","label":"Trabalho muito e sobra pouco dinheiro","pontos":15},
        {"valor":"estagnado","label":"Sinto que estou estagnado e não tenho oportunidade para crescer","pontos":15},
        {"valor":"seguranca","label":"Sei que posso mais, mas ainda falta segurança no meu conhecimento","pontos":15},
        {"valor":"renda","label":"Não sei como aumentar minha renda","pontos":15},
        {"valor":"outra","label":"Outra coisa","pontos":0}
      ]
    },
    {
      "chave": "incomoda_texto", "ordem": 4, "tipo": "texto",
      "enunciado": "Me conta, o que mais te incomoda hoje?",
      "obrigatoria": false,
      "condicao": {"chave":"incomoda","valores":["outra"]},
      "opcoes": []
    }
  ]
}'::jsonb);

select public.quiz_publico('{"lancamento":"lanc-2026-09"}'::jsonb);
