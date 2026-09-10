-- =====================================================================
-- 84 — QUEM ENTROU NO GRUPO
--
-- A dash já guarda quem entrou, mas não mostra em lugar nenhum. E como
-- o webhook do SendFlow às vezes falha, um número só engana: se ele não
-- chega, parece que ninguém entrou.
--
-- Por isso mostramos dois:
--
--   CLICOU NO LINK   registrado pela própria dash, no redirecionamento.
--                    Não prova que entrou, mas prova a intenção — e não
--                    depende de webhook nenhum.
--
--   ENTROU           confirmado pelo SendFlow. É o número real, quando
--                    o webhook funciona.
--
-- A diferença entre os dois é o próprio diagnóstico: muitos cliques e
-- poucas entradas significa webhook falhando ou link do grupo errado.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O FUNIL DO GRUPO
-- ---------------------------------------------------------------------
create or replace function public.dash_grupo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb;
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

  select jsonb_build_object(
    'ok', true,
    'leads', count(*),
    'fizeram_quiz', count(*) filter (where coalesce(fez_quiz, false)),
    'clicaram', count(*) filter (where clicou),
    'entraram', count(*) filter (where coalesce(entrou_grupo, false)),
    'engenheiros_entraram', count(*) filter (
      where coalesce(entrou_grupo, false) and coalesce(engenheiro, false)),

    'pct_entrou', case when count(*) > 0
      then round(100.0 * count(*) filter (where coalesce(entrou_grupo, false))
                 / count(*), 1) end,
    'pct_do_quiz', case when count(*) filter (where coalesce(fez_quiz, false)) > 0
      then round(100.0 * count(*) filter (where coalesce(entrou_grupo, false))
                 / count(*) filter (where coalesce(fez_quiz, false)), 1) end,

    -- clicou e não consta como entrou: ou desistiu na porta do grupo,
    -- ou o webhook do SendFlow não avisou
    'clicou_sem_confirmar', count(*) filter (
      where clicou and not coalesce(entrou_grupo, false)),

    -- entrou sem ter clicado pelo nosso link: veio por outro caminho
    'entrou_sem_clicar', count(*) filter (
      where coalesce(entrou_grupo, false) and not clicou)
  )
  into v_res
  from (
    select
      i.id, i.fez_quiz, i.entrou_grupo, i.engenheiro,
      exists (select 1 from dash.eventos e
              where e.inscricao_id = i.id and e.tipo = 'grupo_click') as clicou
    from dash.inscricoes i
    where i.lancamento_id = v_lanc
  ) t;

  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 2. O DADO POR LEAD, PARA A LISTA E O FILTRO
-- ---------------------------------------------------------------------
create or replace function public.leads_grupo(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_filtro text; v_res jsonb;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  -- 'entrou', 'nao_entrou', 'clicou_sem_entrar' ou vazio para todos
  v_filtro := nullif(p->>'filtro', '');

  select jsonb_agg(jsonb_build_object(
    'inscricao_id', id, 'nome', nome, 'email', email, 'telefone', telefone,
    'engenheiro', engenheiro, 'fez_quiz', fez_quiz,
    'clicou', clicou, 'entrou', entrou, 'quando', grupo_em
  ) order by capturado_em desc)
  into v_res
  from (
    select
      i.id, p2.nome, p2.email, p2.telefone,
      coalesce(i.engenheiro, false) as engenheiro,
      coalesce(i.fez_quiz, false) as fez_quiz,
      coalesce(i.entrou_grupo, false) as entrou,
      i.grupo_em, i.capturado_em,
      exists (select 1 from dash.eventos e
              where e.inscricao_id = i.id and e.tipo = 'grupo_click') as clicou
    from dash.inscricoes i
    left join dash.pessoas p2 on p2.id = i.pessoa_id
    where i.lancamento_id = v_lanc
    limit 2000
  ) t
  where v_filtro is null
     or (v_filtro = 'entrou' and entrou)
     or (v_filtro = 'nao_entrou' and not entrou)
     or (v_filtro = 'clicou_sem_entrar' and clicou and not entrou);

  return jsonb_build_object('ok', true, 'leads', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 3. MARCAR ENTRADA À MÃO
--    Quando o webhook falha, dá para importar a lista do SendFlow por
--    telefone em vez de perder o dado.
--    p: { lancamento, telefones: ['5551...', ...] }
-- ---------------------------------------------------------------------
create or replace function public.marcar_entrada_grupo(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_qtd int := 0; v_nao int := 0; v_fone text;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  for v_fone in
    select dash.norm_phone(v) from jsonb_array_elements_text(
      case when jsonb_typeof(p->'telefones') = 'array'
           then p->'telefones' else '[]'::jsonb end) v
  loop
    continue when v_fone is null;

    with alvo as (
      select i.id from dash.inscricoes i
      join dash.pessoas p2 on p2.id = i.pessoa_id
      where i.lancamento_id = v_lanc and p2.telefone = v_fone
      limit 1
    ),
    marca as (
      update dash.inscricoes set
        entrou_grupo = true,
        grupo_em = coalesce(grupo_em, now())
      where id in (select id from alvo)
      returning 1
    )
    select v_qtd + count(*) into v_qtd from marca;
  end loop;

  select count(*) into v_nao
  from jsonb_array_elements_text(
    case when jsonb_typeof(p->'telefones') = 'array'
         then p->'telefones' else '[]'::jsonb end) v;

  return jsonb_build_object('ok', true, 'marcados', v_qtd,
                            'enviados', v_nao, 'nao_encontrados', v_nao - v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.dash_grupo(jsonb), public.leads_grupo(jsonb),
  public.marcar_entrada_grupo(jsonb) from public, anon, authenticated;
grant execute on function public.dash_grupo(jsonb), public.leads_grupo(jsonb),
  public.marcar_entrada_grupo(jsonb) to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
