-- =====================================================================
-- 75 — QUIZ PADRÃO
--
-- O quiz é praticamente o mesmo todo mês. Hoje ele nasce vazio e você
-- precisa lembrar de copiar do anterior — e esquecer disso significa
-- landing no ar sem qualificação nenhuma.
--
-- Agora o lançamento novo já nasce com as perguntas do último que teve
-- quiz. Continua editável, e o link do grupo NUNCA é copiado: esse tem
-- que ser o do mês, senão os leads caem no grupo errado.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. COPIAR AS PERGUNTAS DE UM LANÇAMENTO PARA OUTRO
-- ---------------------------------------------------------------------
create or replace function dash.copiar_quiz(p_origem uuid, p_destino uuid)
returns int language plpgsql as $$
declare v_qtd int := 0;
begin
  if p_origem is null or p_destino is null or p_origem = p_destino then
    return 0;
  end if;

  -- não sobrescreve quiz que já existe
  if exists (select 1 from dash.quiz_perguntas where lancamento_id = p_destino) then
    return 0;
  end if;

  insert into dash.quiz_perguntas
    (lancamento_id, chave, enunciado, ordem, tipo, obrigatoria, ajuda, opcoes, condicao)
  select p_destino, chave, enunciado, ordem, tipo, obrigatoria, ajuda, opcoes, condicao
  from dash.quiz_perguntas
  where lancamento_id = p_origem
  order by ordem;

  get diagnostics v_qtd = row_count;

  -- a tela de abertura acompanha; o link do grupo não
  update dash.lancamentos d set
    config = coalesce(d.config, '{}'::jsonb)
             || jsonb_build_object('quiz_intro',
                  coalesce((select config->'quiz_intro' from dash.lancamentos
                            where id = p_origem), '{}'::jsonb))
  where d.id = p_destino;

  return v_qtd;
end $$;

-- ---------------------------------------------------------------------
-- 2. LANÇAMENTO NOVO JÁ NASCE COM O QUIZ
-- ---------------------------------------------------------------------
create or replace function dash.quiz_ao_criar()
returns trigger language plpgsql as $$
declare v_origem uuid; v_qtd int;
begin
  -- o último lançamento que tem quiz, tirando o que acabou de nascer
  select l.id into v_origem
  from dash.lancamentos l
  where l.id <> new.id
    and exists (select 1 from dash.quiz_perguntas q where q.lancamento_id = l.id)
  order by coalesce(l.captacao_inicio, l.criado_em) desc
  limit 1;

  if v_origem is null then return new; end if;

  v_qtd := dash.copiar_quiz(v_origem, new.id);

  if v_qtd > 0 then
    raise notice 'quiz copiado de % (% perguntas)', v_origem, v_qtd;
  end if;

  return new;
end $$;

drop trigger if exists tg_quiz_ao_criar on dash.lancamentos;

create trigger tg_quiz_ao_criar
after insert on dash.lancamentos
for each row execute function dash.quiz_ao_criar();

-- ---------------------------------------------------------------------
-- 3. COPIAR PARA UM LANÇAMENTO QUE JÁ EXISTE
--    Para os que foram criados antes desta mudança.
--    p: { lancamento, de }
-- ---------------------------------------------------------------------
create or replace function public.quiz_copiar(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_destino uuid; v_origem uuid; v_qtd int; v_nome text;
begin
  select id into v_destino from dash.lancamentos where slug = p->>'lancamento';
  if v_destino is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  if nullif(p->>'de','') is not null then
    select id into v_origem from dash.lancamentos where slug = p->>'de';
  else
    select l.id into v_origem
    from dash.lancamentos l
    where l.id <> v_destino
      and exists (select 1 from dash.quiz_perguntas q where q.lancamento_id = l.id)
    order by coalesce(l.captacao_inicio, l.criado_em) desc
    limit 1;
  end if;

  if v_origem is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento com quiz para copiar');
  end if;

  -- substituir exige confirmação: apagar quiz por engano custa caro
  if exists (select 1 from dash.quiz_perguntas where lancamento_id = v_destino) then
    if coalesce(p->>'substituir','') <> 'sim' then
      return jsonb_build_object('ok', false,
        'erro', 'este lancamento ja tem quiz. Envie substituir: sim para trocar.');
    end if;
    delete from dash.quiz_perguntas where lancamento_id = v_destino;
  end if;

  v_qtd := dash.copiar_quiz(v_origem, v_destino);
  select nome into v_nome from dash.lancamentos where id = v_origem;

  return jsonb_build_object('ok', true, 'perguntas', v_qtd, 'copiado_de', v_nome,
    'aviso', 'O link do grupo nao foi copiado: cadastre o do lancamento novo em Ajustes.');
end $$;

-- ---------------------------------------------------------------------
-- 4. QUAL LANÇAMENTO SERVE DE MODELO
-- ---------------------------------------------------------------------
create or replace function public.quiz_disponivel(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'slug', slug, 'nome', nome, 'perguntas', n
  ) order by inicio desc)
  into v_res
  from (
    select l.slug, l.nome, coalesce(l.captacao_inicio, l.criado_em) as inicio,
           count(q.id) as n
    from dash.lancamentos l
    join dash.quiz_perguntas q on q.lancamento_id = l.id
    group by l.slug, l.nome, l.captacao_inicio, l.criado_em
  ) t;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.quiz_copiar(jsonb), public.quiz_disponivel(jsonb)
  from public, anon, authenticated;
grant execute on function public.quiz_copiar(jsonb), public.quiz_disponivel(jsonb)
  to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
