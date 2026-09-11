-- =====================================================================
-- 93 — PRÉVIA SEM TABELA TEMPORÁRIA
--
-- A prévia criava uma tabela temporária e a limpava com um DELETE sem
-- WHERE. O Supabase bloqueia isso por segurança — e com razão: é o
-- comando que apaga uma tabela inteira por engano.
--
-- A tabela temporária nem era necessária. Uma CTE faz o mesmo, sem
-- criar nada e sem o risco.
-- =====================================================================

set search_path = dash, public;

create or replace function public.previa_reativacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb; v_por_lanc jsonb; v_por_resp jsonb; v_excluidos jsonb;
begin
  -- a mesma função de filtro que o envio usa, chamada uma vez e
  -- reaproveitada nos três agrupamentos
  with seg as (
    select * from dash.leads_segmentados(p)
  ),
  total as (
    select jsonb_build_object(
      'total', count(*),
      'com_telefone', count(*) filter (where telefone is not null),
      'engenheiros', count(*) filter (where engenheiro)
    ) as j
    from seg
  ),
  por_lanc as (
    select jsonb_agg(jsonb_build_object('lancamento', lancamento, 'leads', n)
             order by n desc) as j
    from (select lancamento, count(*) as n from seg group by lancamento) t
  ),
  por_resp as (
    select jsonb_agg(jsonb_build_object('resposta', resposta, 'leads', n)
             order by n desc) as j
    from (select coalesce(resposta, '(não respondeu)') as resposta, count(*) as n
          from seg group by 1) t
  )
  select total.j, por_lanc.j, por_resp.j
  into v_res, v_por_lanc, v_por_resp
  from total, por_lanc, por_resp;

  -- quantos cada filtro tirou, para a escolha não ser às cegas
  select jsonb_build_object(
    'por_produto_comprado', (
      select count(distinct v.pessoa_id) from dash.vendas v
      where v.status = 'aprovada'
        and jsonb_typeof(p->'excluir_produtos') = 'array'
        and jsonb_array_length(p->'excluir_produtos') > 0
        and exists (
          select 1 from jsonb_array_elements_text(p->'excluir_produtos') x
          where dash.chave_produto(x.value) = dash.chave_produto(v.produto))),
    'ja_receberam', (
      select count(*) from dash.reativacoes r
      where r.campanha = nullif(btrim(coalesce(p->>'campanha','')), ''))
  ) into v_excluidos;

  return jsonb_build_object(
    'ok', true,
    'resumo', coalesce(v_res, jsonb_build_object('total', 0)),
    'por_lancamento', coalesce(v_por_lanc, '[]'::jsonb),
    'por_resposta', coalesce(v_por_resp, '[]'::jsonb),
    'descartados', v_excluidos
  );
end $$;

grant execute on function public.previa_reativacao(jsonb) to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
