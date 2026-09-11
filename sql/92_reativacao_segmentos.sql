-- =====================================================================
-- 92 — SEGMENTAÇÃO DE VERDADE NA REATIVAÇÃO
--
-- A primeira versão tinha dois filtros grossos demais:
--
--   perfil       só separava engenheiro de não engenheiro, jogando
--                técnico, estudante e os demais no mesmo balde
--
--   compradores  excluía quem comprou QUALQUER coisa. Quem comprou só
--                o Protocolo ficava de fora de uma reativação do FPEE,
--                sendo que nunca comprou o FPEE.
--
-- Agora as respostas do quiz vêm do próprio quiz, e a exclusão é por
-- produto — que é como a decisão acontece na prática.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. AS OPÇÕES DISPONÍVEIS PARA FILTRAR
--    Respostas do quiz e produtos vendidos, vindos dos dados reais.
-- ---------------------------------------------------------------------
create or replace function public.opcoes_segmentacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_slugs text[]; v_perguntas jsonb; v_produtos jsonb;
begin
  if jsonb_typeof(p->'lancamentos') = 'array'
     and jsonb_array_length(p->'lancamentos') > 0 then
    select array_agg(v) into v_slugs
    from jsonb_array_elements_text(p->'lancamentos') v;
  end if;

  -- as perguntas do quiz e suas respostas, com quantos responderam cada
  -- Em três etapas: contar, montar cada resposta, agrupar por pergunta.
  -- Tentar fazer tudo numa consulta só aninha agregação dentro de
  -- agregação, o que o Postgres não aceita.
  with contagem as (
    select r.pergunta_chave,
           r.resposta_valor,
           max(r.resposta_label) as label,
           count(*) as leads
    from dash.quiz_respostas r
    join dash.inscricoes i2 on i2.id = r.inscricao_id
    join dash.lancamentos l2 on l2.id = i2.lancamento_id
    where (v_slugs is null or l2.slug = any(v_slugs))
    group by r.pergunta_chave, r.resposta_valor
  ),
  por_pergunta as (
    select pergunta_chave,
           jsonb_agg(jsonb_build_object(
             'valor', resposta_valor,
             'label', coalesce(nullif(label, ''), resposta_valor),
             'leads', leads
           ) order by leads desc) as respostas
    from contagem
    group by pergunta_chave
  ),
  enunciados as (
    select q.chave, min(q.enunciado) as enunciado, min(q.ordem) as ordem
    from dash.quiz_perguntas q
    join dash.lancamentos l on l.id = q.lancamento_id
    where (v_slugs is null or l.slug = any(v_slugs))
    group by q.chave
  )
  select jsonb_agg(jsonb_build_object(
    'chave', e.chave, 'enunciado', e.enunciado, 'respostas', pp.respostas
  ) order by e.ordem)
  into v_perguntas
  from enunciados e
  join por_pergunta pp on pp.pergunta_chave = e.chave;

  -- os produtos que já foram vendidos, para servir de exclusão
  select jsonb_agg(jsonb_build_object(
    'produto', produto, 'compradores', n
  ) order by n desc)
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
    'perguntas', coalesce(v_perguntas, '[]'::jsonb),
    'produtos', coalesce(v_produtos, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. O FILTRO, EM UM LUGAR SÓ
--
--    Prévia e envio precisam usar exatamente a mesma regra. Separar as
--    duas implementações garante que uma hora elas divergem e a prévia
--    passa a mentir.
--
--    p: {
--      lancamentos: ['fpee-2026-01'],
--      pergunta: 'qual_e_a_sua_formacao_na_area_eletrica',
--      respostas: ['eng_eletricista','tecnico'],   vazio = todas
--      excluir_produtos: ['FPEE- Formação...'],    vazio = nenhum
--      excluir_lancamento_atual: true,
--      campanha: 'reativacao-set-26'
--    }
-- ---------------------------------------------------------------------
create or replace function dash.leads_segmentados(p jsonb)
returns table (
  pessoa_id uuid, inscricao_id uuid, nome text, email text, telefone text,
  lancamento text, engenheiro boolean, resposta text, capturado_em timestamptz
) language plpgsql stable as $$
declare
  v_slugs text[]; v_respostas text[]; v_produtos text[];
  v_pergunta text; v_campanha text; v_atual uuid;
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

  v_pergunta := nullif(p->>'pergunta', '');
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
      (select r.resposta_valor from dash.quiz_respostas r
       where r.inscricao_id = i.id
         and (v_pergunta is null or r.pergunta_chave = v_pergunta)
       limit 1) as r_valor
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
    -- a resposta do quiz escolhida
    (v_respostas is null or b.r_valor = any(v_respostas))

    -- quem comprou os produtos marcados não recebe. Sem produto
    -- marcado, ninguém é excluído por compra.
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

-- ---------------------------------------------------------------------
-- 3. PRÉVIA
-- ---------------------------------------------------------------------
create or replace function public.previa_reativacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb; v_por_lanc jsonb; v_por_resp jsonb; v_excluidos jsonb;
begin
  create temp table if not exists tmp_seg on commit drop as
  select * from dash.leads_segmentados(p);

  delete from tmp_seg;
  insert into tmp_seg select * from dash.leads_segmentados(p);

  select jsonb_build_object(
    'total', count(*),
    'com_telefone', count(*) filter (where telefone is not null),
    'engenheiros', count(*) filter (where engenheiro)
  ) into v_res from tmp_seg;

  select jsonb_agg(jsonb_build_object('lancamento', lancamento, 'leads', n)
           order by n desc)
  into v_por_lanc
  from (select lancamento, count(*) as n from tmp_seg group by lancamento) t;

  select jsonb_agg(jsonb_build_object('resposta', resposta, 'leads', n)
           order by n desc)
  into v_por_resp
  from (select coalesce(resposta, '(não respondeu)') as resposta, count(*) as n
        from tmp_seg group by 1) t;

  -- quantos cada filtro tirou, para a escolha não ser às cegas
  select jsonb_build_object(
    'por_produto_comprado', (
      select count(distinct v.pessoa_id) from dash.vendas v
      where v.status = 'aprovada'
        and jsonb_typeof(p->'excluir_produtos') = 'array'
        and exists (
          select 1 from jsonb_array_elements_text(p->'excluir_produtos') x
          where dash.chave_produto(x.value) = dash.chave_produto(v.produto))),
    'ja_receberam', (
      select count(*) from dash.reativacoes r
      where r.campanha = nullif(btrim(coalesce(p->>'campanha','')), ''))
  ) into v_excluidos;

  return jsonb_build_object(
    'ok', true,
    'resumo', v_res,
    'por_lancamento', coalesce(v_por_lanc, '[]'::jsonb),
    'por_resposta', coalesce(v_por_resp, '[]'::jsonb),
    'descartados', v_excluidos
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. LOTE DE ENVIO — mesma função de filtro
-- ---------------------------------------------------------------------
create or replace function public.lote_reativacao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_campanha text; v_limite int; v_res jsonb;
begin
  v_campanha := nullif(btrim(coalesce(p->>'campanha','')), '');
  if v_campanha is null then
    return jsonb_build_object('ok', false, 'erro', 'de um nome a campanha');
  end if;

  v_limite := least(coalesce(nullif(p->>'limite','')::int, 200), 500);

  select jsonb_agg(jsonb_build_object(
    'pessoa_id', pessoa_id, 'inscricao_id', inscricao_id,
    'nome', nome, 'email', email, 'telefone', telefone,
    'lancamento', lancamento, 'engenheiro', engenheiro, 'resposta', resposta
  ))
  into v_res
  from (
    select * from dash.leads_segmentados(p)
    order by capturado_em desc
    limit v_limite
  ) t;

  return jsonb_build_object('ok', true, 'campanha', v_campanha,
                            'leads', coalesce(v_res, '[]'::jsonb));
end $$;

revoke all on function public.opcoes_segmentacao(jsonb) from public, anon, authenticated;
grant execute on function public.opcoes_segmentacao(jsonb),
  public.previa_reativacao(jsonb), public.lote_reativacao(jsonb) to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
