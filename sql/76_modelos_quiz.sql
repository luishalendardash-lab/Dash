-- =====================================================================
-- 76 — MODELOS DE QUIZ
--
-- Copiar do lançamento anterior funciona, mas depende de o anterior
-- estar certo. Se alguém mexeu nele para testar, o erro se propaga.
--
-- Um modelo salvo é diferente: é a versão validada, guardada à parte.
-- Na criação do lançamento você escolhe qual usar, e o quiz nasce
-- pronto.
-- =====================================================================

set search_path = dash, public;

create table if not exists dash.quiz_modelos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null unique,
  descricao   text,
  perguntas   jsonb not null default '[]'::jsonb,
  intro       jsonb not null default '{}'::jsonb,
  padrao      boolean not null default false,
  criado_em   timestamptz not null default now(),
  atualizado  timestamptz not null default now()
);

alter table dash.quiz_modelos enable row level security;

-- só um modelo pode ser o padrão
create unique index if not exists ix_quiz_modelo_padrao
  on dash.quiz_modelos (padrao) where padrao;

-- ---------------------------------------------------------------------
-- 1. SALVAR UM MODELO A PARTIR DE UM LANÇAMENTO
--    p: { lancamento, nome, descricao, padrao }
-- ---------------------------------------------------------------------
create or replace function public.salvar_modelo_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_perguntas jsonb; v_intro jsonb; v_nome text; v_id uuid;
begin
  v_nome := nullif(btrim(p->>'nome'), '');
  if v_nome is null then
    return jsonb_build_object('ok', false, 'erro', 'dê um nome ao modelo');
  end if;

  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select jsonb_agg(jsonb_build_object(
    'chave', chave, 'enunciado', enunciado, 'ordem', ordem,
    'tipo', tipo, 'obrigatoria', obrigatoria, 'ajuda', ajuda,
    'opcoes', opcoes, 'condicao', condicao
  ) order by ordem)
  into v_perguntas
  from dash.quiz_perguntas where lancamento_id = v_lanc;

  if v_perguntas is null then
    return jsonb_build_object('ok', false, 'erro', 'este lancamento nao tem quiz');
  end if;

  select coalesce(config->'quiz_intro', '{}'::jsonb) into v_intro
  from dash.lancamentos where id = v_lanc;

  -- se este vai ser o padrão, os outros deixam de ser
  if coalesce((p->>'padrao')::boolean, false) then
    update dash.quiz_modelos set padrao = false where padrao;
  end if;

  insert into dash.quiz_modelos (nome, descricao, perguntas, intro, padrao)
  values (v_nome, nullif(btrim(p->>'descricao'),''), v_perguntas, v_intro,
          coalesce((p->>'padrao')::boolean, false))
  on conflict (nome) do update set
    descricao = excluded.descricao,
    perguntas = excluded.perguntas,
    intro = excluded.intro,
    padrao = excluded.padrao,
    atualizado = now()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'nome', v_nome,
    'perguntas', jsonb_array_length(v_perguntas));
end $$;

-- ---------------------------------------------------------------------
-- 2. LISTAR
-- ---------------------------------------------------------------------
create or replace function public.modelos_quiz(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'id', id, 'nome', nome, 'descricao', descricao,
    'perguntas', jsonb_array_length(perguntas),
    'padrao', padrao, 'atualizado', atualizado
  ) order by padrao desc, nome)
  into v_res from dash.quiz_modelos;

  return jsonb_build_object('ok', true, 'modelos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 3. APLICAR NUM LANÇAMENTO
--    p: { lancamento, modelo, substituir }
-- ---------------------------------------------------------------------
create or replace function public.aplicar_modelo_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_modelo record; v_item jsonb; v_qtd int := 0;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  if nullif(p->>'modelo','') is not null then
    select * into v_modelo from dash.quiz_modelos
    where nome = p->>'modelo' or id::text = p->>'modelo';
  else
    select * into v_modelo from dash.quiz_modelos where padrao limit 1;
  end if;

  if v_modelo.id is null then
    return jsonb_build_object('ok', false, 'erro', 'modelo nao encontrado');
  end if;

  if exists (select 1 from dash.quiz_perguntas where lancamento_id = v_lanc) then
    if coalesce(p->>'substituir','') <> 'sim' then
      return jsonb_build_object('ok', false,
        'erro', 'este lancamento ja tem quiz. Envie substituir: sim para trocar.');
    end if;
    delete from dash.quiz_perguntas where lancamento_id = v_lanc;
  end if;

  for v_item in select * from jsonb_array_elements(v_modelo.perguntas)
  loop
    insert into dash.quiz_perguntas
      (lancamento_id, chave, enunciado, ordem, tipo, obrigatoria, ajuda, opcoes, condicao)
    values (
      v_lanc,
      v_item->>'chave',
      v_item->>'enunciado',
      coalesce((v_item->>'ordem')::int, v_qtd + 1),
      coalesce(nullif(v_item->>'tipo',''), 'multipla'),
      coalesce((v_item->>'obrigatoria')::boolean, true),
      nullif(v_item->>'ajuda',''),
      coalesce(v_item->'opcoes', '[]'::jsonb),
      case when jsonb_typeof(v_item->'condicao') = 'object'
           then v_item->'condicao' end
    );
    v_qtd := v_qtd + 1;
  end loop;

  -- a tela de abertura vem junto; o link do grupo continua sendo do mês
  update dash.lancamentos set
    config = coalesce(config, '{}'::jsonb)
             || jsonb_build_object('quiz_intro', v_modelo.intro)
  where id = v_lanc;

  return jsonb_build_object('ok', true, 'perguntas', v_qtd,
    'modelo', v_modelo.nome,
    'aviso', 'O link do grupo nao vem no modelo: cadastre o do lancamento em Ajustes.');
end $$;

-- ---------------------------------------------------------------------
-- 4. APAGAR
-- ---------------------------------------------------------------------
create or replace function public.apagar_modelo_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_qtd int;
begin
  with a as (
    delete from dash.quiz_modelos
    where nome = p->>'modelo' or id::text = p->>'modelo'
    returning 1
  )
  select count(*) into v_qtd from a;

  return jsonb_build_object('ok', v_qtd > 0,
    'erro', case when v_qtd = 0 then 'modelo nao encontrado' end);
end $$;

-- ---------------------------------------------------------------------
-- 5. O LANÇAMENTO NOVO USA O MODELO PADRÃO
--    Substitui a cópia do anterior: o modelo é a versão validada, o
--    lançamento anterior pode ter sido mexido para teste.
-- ---------------------------------------------------------------------
create or replace function dash.quiz_ao_criar()
returns trigger language plpgsql as $$
declare v_modelo record; v_item jsonb; v_qtd int := 0; v_origem uuid;
begin
  select * into v_modelo from dash.quiz_modelos where padrao limit 1;

  if v_modelo.id is not null then
    for v_item in select * from jsonb_array_elements(v_modelo.perguntas)
    loop
      insert into dash.quiz_perguntas
        (lancamento_id, chave, enunciado, ordem, tipo, obrigatoria, ajuda, opcoes, condicao)
      values (
        new.id, v_item->>'chave', v_item->>'enunciado',
        coalesce((v_item->>'ordem')::int, v_qtd + 1),
        coalesce(nullif(v_item->>'tipo',''), 'multipla'),
        coalesce((v_item->>'obrigatoria')::boolean, true),
        nullif(v_item->>'ajuda',''),
        coalesce(v_item->'opcoes', '[]'::jsonb),
        case when jsonb_typeof(v_item->'condicao') = 'object'
             then v_item->'condicao' end
      );
      v_qtd := v_qtd + 1;
    end loop;

    update dash.lancamentos set
      config = coalesce(config, '{}'::jsonb)
               || jsonb_build_object('quiz_intro', v_modelo.intro)
    where id = new.id;

    return new;
  end if;

  -- sem modelo salvo, cai para o comportamento anterior
  select l.id into v_origem
  from dash.lancamentos l
  where l.id <> new.id
    and exists (select 1 from dash.quiz_perguntas q where q.lancamento_id = l.id)
  order by coalesce(l.captacao_inicio, l.criado_em) desc
  limit 1;

  if v_origem is not null then
    perform dash.copiar_quiz(v_origem, new.id);
  end if;

  return new;
end $$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.salvar_modelo_quiz(jsonb), public.modelos_quiz(jsonb),
  public.aplicar_modelo_quiz(jsonb), public.apagar_modelo_quiz(jsonb)
  from public, anon, authenticated;
grant execute on function public.salvar_modelo_quiz(jsonb), public.modelos_quiz(jsonb),
  public.aplicar_modelo_quiz(jsonb), public.apagar_modelo_quiz(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
