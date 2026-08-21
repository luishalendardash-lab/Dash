-- =====================================================================
-- 48 — DUAS LEITURAS SEPARADAS
--
-- FATURAMENTO DO NEGÓCIO
--   tudo que entrou no período, de todas as plataformas, tenha vindo de
--   lançamento ou não. É o número do caixa.
--
-- RESULTADO DO LANÇAMENTO
--   só o que foi vendido na janela do carrinho, e só dos produtos
--   daquele lançamento. É o número que diz se o lançamento pagou.
--
-- Os dois quase nunca batem, e está certo: quem compra fora do carrinho,
-- ou compra outro produto do catálogo, entra no faturamento e não no
-- resultado do lançamento.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. JANELA E PRODUTOS DE CADA LANÇAMENTO
-- ---------------------------------------------------------------------
alter table dash.lancamentos
  add column if not exists carrinho_abre  timestamptz,
  add column if not exists carrinho_fecha timestamptz;

comment on column dash.lancamentos.carrinho_abre is
  'inicio da janela de venda. Vazio: usa o inicio da captacao.';
comment on column dash.lancamentos.carrinho_fecha is
  'fim da janela de venda. Vazio: vai ate o inicio do lancamento seguinte.';

-- ---------------------------------------------------------------------
-- 2. GUARDAR A CONFIGURAÇÃO
--    p: { lancamento, carrinho_abre, carrinho_fecha, produtos: [...] }
-- ---------------------------------------------------------------------
create or replace function public.salvar_escopo_lancamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  update dash.lancamentos set
    carrinho_abre = case when p ? 'carrinho_abre'
      then dash.texto_para_data(p->>'carrinho_abre') else carrinho_abre end,
    carrinho_fecha = case when p ? 'carrinho_fecha'
      then dash.texto_para_data(p->>'carrinho_fecha') else carrinho_fecha end,
    config = case when p ? 'produtos'
      then coalesce(config, '{}'::jsonb) || jsonb_build_object('produtos', p->'produtos')
      else config end
  where id = v_lanc;

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 3. A JANELA EFETIVA
--    Sem carrinho definido, vai do início da captação até o lançamento
--    seguinte começar — que é o comportamento que já valia.
-- ---------------------------------------------------------------------
create or replace function dash.janela_lancamento(p_lanc uuid)
returns table (de timestamptz, ate timestamptz)
language sql stable as $$
  select
    coalesce(l.carrinho_abre, l.captacao_inicio, l.criado_em),
    coalesce(
      l.carrinho_fecha,
      (select min(coalesce(l2.captacao_inicio, l2.criado_em)) - interval '1 second'
       from dash.lancamentos l2
       where coalesce(l2.captacao_inicio, l2.criado_em)
             > coalesce(l.captacao_inicio, l.criado_em)),
      now()
    )
  from dash.lancamentos l where l.id = p_lanc;
$$;

-- ---------------------------------------------------------------------
-- 4. RESULTADO DO LANÇAMENTO
--    Filtra por janela e, quando configurados, pelos produtos.
-- ---------------------------------------------------------------------
create or replace function public.dash_resumo_lancamento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_nome text; v_meta numeric;
  v_de timestamptz; v_ate timestamptz;
  v_produtos text[]; v_investido numeric; v_res jsonb;
  v_todos jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, nome, meta_faturamento into v_lanc, v_nome, v_meta
    from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id, nome, meta_faturamento into v_lanc, v_nome, v_meta
    from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento');
  end if;

  -- período: o que veio na chamada vence a configuração do lançamento
  if nullif(p->>'de','') is not null then
    v_de := dash.texto_para_data(p->>'de');
    v_ate := coalesce(dash.texto_para_data(p->>'ate'), now());
  else
    select de, ate into v_de, v_ate from dash.janela_lancamento(v_lanc);
  end if;

  -- produtos: o que veio na chamada, senão o configurado, senão todos
  if jsonb_typeof(p->'produtos') = 'array'
     and jsonb_array_length(p->'produtos') > 0 then
    select array_agg(dash.chave_produto(v))
    into v_produtos from jsonb_array_elements_text(p->'produtos') v;
  else
    select array_agg(dash.chave_produto(v))
    into v_produtos
    from dash.lancamentos l, jsonb_array_elements_text(
      case when jsonb_typeof(l.config->'produtos') = 'array'
           then l.config->'produtos' else '[]'::jsonb end) v
    where l.id = v_lanc;
  end if;

  select coalesce(round(sum(gasto), 2), 0) into v_investido
  from dash.ads_insights where lancamento_id = v_lanc;

  -- o catálogo vendido na janela, para a tela oferecer o filtro
  select jsonb_agg(jsonb_build_object(
    'produto', produto, 'vendas', n, 'receita', receita,
    'no_lancamento', v_produtos is null
                     or dash.chave_produto(produto) = any(v_produtos)
  ) order by receita desc)
  into v_todos
  from (
    select coalesce(produto, '(sem produto)') as produto,
           count(*) as n, round(sum(valor_bruto), 2) as receita
    from dash.vendas
    where status = 'aprovada' and ocorreu_em between v_de and v_ate
    group by 1
  ) t;

  select jsonb_build_object(
    'ok', true,
    'lancamento', v_nome,
    'de', v_de, 'ate', v_ate,
    'produtos_filtrados', coalesce(array_length(v_produtos, 1), 0),
    'vendas', count(*) filter (where status = 'aprovada'),
    'receita', round(coalesce(sum(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'liquido', round(coalesce(sum(
      case when valor_liquido > 0 then valor_liquido else valor_bruto * 0.9 end
    ) filter (where status = 'aprovada'), 0), 2),
    'ticket', round(coalesce(avg(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'reembolsos', count(*) filter (where status in ('reembolsada','chargeback')),
    'com_lead', count(*) filter (where status = 'aprovada' and inscricao_id is not null),
    'sem_lead', count(*) filter (where status = 'aprovada' and inscricao_id is null),
    'atribuicao', case when count(*) filter (where status = 'aprovada') > 0
      then round(100.0 * count(*) filter (where status = 'aprovada' and inscricao_id is not null)
                 / count(*) filter (where status = 'aprovada'), 1) end,
    'investido', v_investido,
    'roas', case when v_investido > 0
      then round(coalesce(sum(valor_bruto) filter (where status = 'aprovada'), 0)
                 / v_investido, 2) end,
    'cpa', case when v_investido > 0 and count(*) filter (where status = 'aprovada') > 0
      then round(v_investido / count(*) filter (where status = 'aprovada'), 2) end,
    'lucro', case when v_investido > 0
      then round(coalesce(sum(
        case when valor_liquido > 0 then valor_liquido else valor_bruto * 0.9 end
      ) filter (where status = 'aprovada'), 0) - v_investido, 2) end,
    'meta_faturamento', v_meta,
    'pct_da_meta', case when v_meta > 0
      then round(100.0 * coalesce(sum(valor_bruto) filter (where status = 'aprovada'), 0)
                 / v_meta, 1) end,
    'catalogo', coalesce(v_todos, '[]'::jsonb)
  ) into v_res
  from dash.vendas
  where ocorreu_em between v_de and v_ate
    and (v_produtos is null or dash.chave_produto(produto) = any(v_produtos));

  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 5. FATURAMENTO DO NEGÓCIO
--    Todas as plataformas, no período. Nada de lançamento aqui.
-- ---------------------------------------------------------------------
create or replace function public.dash_faturamento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_de timestamptz; v_ate timestamptz; v_produtos text[];
  v_res jsonb; v_plat jsonb; v_prod jsonb; v_dias jsonb; v_lanc jsonb;
begin
  v_de := coalesce(dash.texto_para_data(p->>'de'), now() - interval '30 days');
  v_ate := coalesce(dash.texto_para_data(p->>'ate'), now());

  if jsonb_typeof(p->'produtos') = 'array'
     and jsonb_array_length(p->'produtos') > 0 then
    select array_agg(dash.chave_produto(v))
    into v_produtos from jsonb_array_elements_text(p->'produtos') v;
  end if;

  -- por plataforma
  select jsonb_agg(jsonb_build_object(
    'plataforma', plataforma, 'vendas', n,
    'receita', receita, 'liquido', liquido, 'ticket', ticket
  ) order by receita desc)
  into v_plat
  from (
    select coalesce(plataforma, 'outra') as plataforma,
           count(*) as n,
           round(sum(valor_bruto), 2) as receita,
           round(sum(case when valor_liquido > 0
                          then valor_liquido else valor_bruto * 0.9 end), 2) as liquido,
           round(avg(valor_bruto), 2) as ticket
    from dash.vendas
    where status = 'aprovada' and ocorreu_em between v_de and v_ate
      and (v_produtos is null or dash.chave_produto(produto) = any(v_produtos))
    group by 1
  ) t;

  -- por produto
  select jsonb_agg(jsonb_build_object(
    'produto', produto, 'vendas', n, 'receita', receita, 'ticket', ticket
  ) order by receita desc)
  into v_prod
  from (
    select coalesce(produto, '(sem produto)') as produto,
           count(*) as n, round(sum(valor_bruto), 2) as receita,
           round(avg(valor_bruto), 2) as ticket
    from dash.vendas
    where status = 'aprovada' and ocorreu_em between v_de and v_ate
      and (v_produtos is null or dash.chave_produto(produto) = any(v_produtos))
    group by 1
  ) t;

  -- dia a dia
  select jsonb_agg(jsonb_build_object('dia', dia, 'vendas', n, 'receita', receita)
                   order by dia)
  into v_dias
  from (
    select ocorreu_em::date as dia, count(*) as n, round(sum(valor_bruto), 2) as receita
    from dash.vendas
    where status = 'aprovada' and ocorreu_em between v_de and v_ate
      and (v_produtos is null or dash.chave_produto(produto) = any(v_produtos))
    group by 1
  ) t;

  -- quanto veio de lançamento e quanto veio de fora
  select jsonb_agg(jsonb_build_object(
    'lancamento', nome, 'vendas', n, 'receita', receita) order by receita desc)
  into v_lanc
  from (
    select coalesce(l.nome, 'Fora de lançamento') as nome,
           count(*) as n, round(sum(v.valor_bruto), 2) as receita
    from dash.vendas v
    left join dash.lancamentos l on l.id = v.lancamento_id
    where v.status = 'aprovada' and v.ocorreu_em between v_de and v_ate
      and (v_produtos is null or dash.chave_produto(v.produto) = any(v_produtos))
    group by 1
  ) t;

  select jsonb_build_object(
    'ok', true, 'de', v_de, 'ate', v_ate,
    'vendas', count(*) filter (where status = 'aprovada'),
    'receita', round(coalesce(sum(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'liquido', round(coalesce(sum(
      case when valor_liquido > 0 then valor_liquido else valor_bruto * 0.9 end
    ) filter (where status = 'aprovada'), 0), 2),
    'ticket', round(coalesce(avg(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'reembolsos', count(*) filter (where status in ('reembolsada','chargeback')),
    'valor_reembolsado', round(coalesce(sum(valor_bruto)
      filter (where status in ('reembolsada','chargeback')), 0), 2),
    'por_plataforma', coalesce(v_plat, '[]'::jsonb),
    'por_produto', coalesce(v_prod, '[]'::jsonb),
    'por_lancamento', coalesce(v_lanc, '[]'::jsonb),
    'por_dia', coalesce(v_dias, '[]'::jsonb)
  ) into v_res
  from dash.vendas
  where ocorreu_em between v_de and v_ate
    and (v_produtos is null or dash.chave_produto(produto) = any(v_produtos));

  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.dash_faturamento(jsonb), public.salvar_escopo_lancamento(jsonb)
  from public, anon, authenticated;
grant execute on function public.dash_faturamento(jsonb), public.dash_resumo_lancamento(jsonb),
  public.salvar_escopo_lancamento(jsonb) to service_role;

select 'pronto' as status;
