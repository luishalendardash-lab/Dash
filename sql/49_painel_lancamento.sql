-- =====================================================================
-- 49 — PAINEL COMPLETO DO LANÇAMENTO
--
-- O que a Home precisa responder de uma olhada:
--
--   quanto entrou, quanto sobrou, quanto custou
--   quantos leads viraram compradores, e quantos ENGENHEIROS viraram
--   quanto custou cada venda, e quanto custou cada venda de engenheiro
--   por qual plataforma o dinheiro entrou
--   quais produtos venderam — principal, order bump, upsell
--
-- A separação engenheiro x geral é o ponto: se o engenheiro converte 3x
-- mais, o CPL dele pode ser 3x mais caro e ainda valer a pena. Sem
-- separar, os dois se anulam na média e a decisão sai errada.
-- =====================================================================

set search_path = dash, public;

create or replace function public.dash_resumo_lancamento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_nome text; v_meta numeric; v_meta_leads int;
  v_de timestamptz; v_ate timestamptz; v_produtos text[];
  v_investido numeric;
  v_leads int; v_engs int;
  v_compradores int; v_comp_eng int;
  v_receita numeric; v_receita_eng numeric;
  v_liquido numeric; v_vendas int; v_reemb int; v_valor_reemb numeric;
  v_com_lead int; v_sem_lead int; v_ticket numeric;
  v_plataformas jsonb; v_prods jsonb; v_catalogo jsonb; v_dias jsonb;
  v_custos numeric;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, nome, meta_faturamento, meta_leads
    into v_lanc, v_nome, v_meta, v_meta_leads
    from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id, nome, meta_faturamento, meta_leads
    into v_lanc, v_nome, v_meta, v_meta_leads
    from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento');
  end if;

  -- ---- janela
  if nullif(p->>'de','') is not null then
    v_de := dash.texto_para_data(p->>'de');
    v_ate := coalesce(dash.texto_para_data(p->>'ate'), now());
  else
    select de, ate into v_de, v_ate from dash.janela_lancamento(v_lanc);
  end if;

  -- ---- produtos
  if jsonb_typeof(p->'produtos') = 'array'
     and jsonb_array_length(p->'produtos') > 0 then
    select array_agg(dash.chave_produto(v))
    into v_produtos from jsonb_array_elements_text(p->'produtos') v;
  else
    select array_agg(dash.chave_produto(v)) into v_produtos
    from dash.lancamentos l, jsonb_array_elements_text(
      case when jsonb_typeof(l.config->'produtos') = 'array'
           then l.config->'produtos' else '[]'::jsonb end) v
    where l.id = v_lanc;
  end if;

  -- ---- investimento
  select coalesce(round(sum(gasto), 2), 0) into v_investido
  from dash.ads_insights where lancamento_id = v_lanc;

  -- ---- base de leads
  select count(*), count(*) filter (where engenheiro)
  into v_leads, v_engs
  from dash.inscricoes where lancamento_id = v_lanc;

  -- ---- vendas na janela e nos produtos escolhidos
  -- Uma view temporária por chamada seria mais legível, mas tabela
  -- temporária dentro de função quebra no pool de conexões do PostgREST:
  -- a sessão é reaproveitada e a tabela sobrevive entre chamadas. Por
  -- isso a condição se repete em cada consulta abaixo.
  select
    count(*) filter (where status = 'aprovada'),
    round(coalesce(sum(bruto) filter (where status = 'aprovada'), 0), 2),
    round(coalesce(sum(liquido) filter (where status = 'aprovada'), 0), 2),
    round(coalesce(avg(bruto) filter (where status = 'aprovada'), 0), 2),
    count(*) filter (where status in ('reembolsada','chargeback')),
    round(coalesce(sum(bruto) filter (where status in ('reembolsada','chargeback')), 0), 2),
    count(*) filter (where status = 'aprovada' and inscricao_id is not null),
    count(*) filter (where status = 'aprovada' and inscricao_id is null),
    round(coalesce(sum(bruto) filter (where status = 'aprovada' and engenheiro), 0), 2)
  into v_vendas, v_receita, v_liquido, v_ticket, v_reemb, v_valor_reemb,
       v_com_lead, v_sem_lead, v_receita_eng
  from (
    select v.id, v.inscricao_id, coalesce(i.engenheiro, false) as engenheiro,
           v.valor_bruto as bruto,
           case when v.valor_liquido > 0 then v.valor_liquido
                else v.valor_bruto * 0.9 end as liquido,
           v.status
    from dash.vendas v
    left join dash.inscricoes i on i.id = v.inscricao_id
    where v.ocorreu_em between v_de and v_ate
      and (v_produtos is null or dash.chave_produto(v.produto) = any(v_produtos))
  ) tv;

  -- compradores distintos, e quantos deles eram engenheiros
  select count(distinct v.inscricao_id),
         count(distinct v.inscricao_id) filter (where coalesce(i.engenheiro, false))
  into v_compradores, v_comp_eng
  from dash.vendas v
  left join dash.inscricoes i on i.id = v.inscricao_id
  where v.ocorreu_em between v_de and v_ate
    and (v_produtos is null or dash.chave_produto(v.produto) = any(v_produtos))
    and v.status = 'aprovada' and v.inscricao_id is not null;

  -- ---- descontos configurados (imposto, coprodução, comissão)
  select coalesce(sum(
    case tipo
      when 'percentual' then v_receita * valor / 100
      when 'por_venda'  then valor * v_vendas
      when 'fixo'       then valor
      else 0 end), 0)
  into v_custos
  from dash.custos where ativo;

  -- ---- por plataforma
  select jsonb_agg(jsonb_build_object(
    'plataforma', plataforma, 'vendas', n, 'receita', receita,
    'liquido', liq, 'ticket', ticket, 'pct', pct
  ) order by receita desc)
  into v_plataformas
  from (
    select plataforma, count(*) as n,
           round(sum(bruto), 2) as receita,
           round(sum(liquido), 2) as liq,
           round(avg(bruto), 2) as ticket,
           case when v_receita > 0
                then round(100.0 * sum(bruto) / v_receita, 1) end as pct
    from (
      select coalesce(v.plataforma, 'outra') as plataforma, v.valor_bruto as bruto,
             case when v.valor_liquido > 0 then v.valor_liquido
                  else v.valor_bruto * 0.9 end as liquido
      from dash.vendas v
      where v.ocorreu_em between v_de and v_ate
        and (v_produtos is null or dash.chave_produto(v.produto) = any(v_produtos))
        and v.status = 'aprovada'
    ) tv
    group by plataforma
  ) t;

  -- ---- por produto: mostra order bump e upsell sem precisar configurar
  select jsonb_agg(jsonb_build_object(
    'produto', produto, 'vendas', n, 'receita', receita,
    'ticket', ticket, 'pct', pct,
    'compradores', compradores
  ) order by receita desc)
  into v_prods
  from (
    select produto, count(*) as n,
           round(sum(bruto), 2) as receita,
           round(avg(bruto), 2) as ticket,
           count(distinct inscricao_id) as compradores,
           case when v_receita > 0
                then round(100.0 * sum(bruto) / v_receita, 1) end as pct
    from (
      select coalesce(v.produto, '(sem produto)') as produto, v.valor_bruto as bruto,
             v.inscricao_id
      from dash.vendas v
      where v.ocorreu_em between v_de and v_ate
        and (v_produtos is null or dash.chave_produto(v.produto) = any(v_produtos))
        and v.status = 'aprovada'
    ) tv
    group by produto
  ) t;

  -- ---- catálogo da janela, incluindo o que ficou de fora do filtro
  select jsonb_agg(jsonb_build_object(
    'produto', produto, 'vendas', n, 'receita', receita,
    'no_lancamento', v_produtos is null
                     or dash.chave_produto(produto) = any(v_produtos)
  ) order by receita desc)
  into v_catalogo
  from (
    select coalesce(produto, '(sem produto)') as produto,
           count(*) as n, round(sum(valor_bruto), 2) as receita
    from dash.vendas
    where status = 'aprovada' and ocorreu_em between v_de and v_ate
    group by 1
  ) t;

  -- ---- vendas por dia
  select jsonb_agg(jsonb_build_object('dia', dia, 'vendas', n, 'receita', receita)
                   order by dia)
  into v_dias
  from (
    select dia, count(*) as n, round(sum(bruto), 2) as receita
    from (
      select v.ocorreu_em::date as dia, v.valor_bruto as bruto
      from dash.vendas v
      where v.ocorreu_em between v_de and v_ate
        and (v_produtos is null or dash.chave_produto(v.produto) = any(v_produtos))
        and v.status = 'aprovada'
    ) tv
    group by dia
  ) t;

  return jsonb_build_object(
    'ok', true,
    'lancamento', v_nome,
    'de', v_de, 'ate', v_ate,
    'produtos_filtrados', coalesce(array_length(v_produtos, 1), 0),

    -- ---- entrada
    'investido', v_investido,
    'receita', v_receita,
    'liquido', v_liquido,
    'custos', round(v_custos, 2),
    -- o que sobra de verdade: líquido da plataforma, menos os descontos
    -- cadastrados, menos o que foi para tráfego
    'lucro', round(v_liquido - v_custos - v_investido, 2),
    'margem', case when v_receita > 0
      then round(100.0 * (v_liquido - v_custos - v_investido) / v_receita, 1) end,

    -- ---- volume
    'vendas', v_vendas,
    'compradores', v_compradores,
    'ticket', v_ticket,
    'reembolsos', v_reemb,
    'valor_reembolsado', v_valor_reemb,
    'com_lead', v_com_lead,
    'sem_lead', v_sem_lead,
    'atribuicao', case when v_vendas > 0
      then round(100.0 * v_com_lead / v_vendas, 1) end,

    -- ---- base
    'leads', v_leads,
    'engenheiros', v_engs,
    'pct_engenheiro', case when v_leads > 0
      then round(100.0 * v_engs / v_leads, 1) end,

    -- ---- conversão: o par que decide onde colocar verba
    'conversao', case when v_leads > 0
      then round(100.0 * v_compradores / v_leads, 2) end,
    'conversao_engenheiro', case when v_engs > 0
      then round(100.0 * v_comp_eng / v_engs, 2) end,
    'compradores_engenheiros', v_comp_eng,

    -- ---- custo
    'cpl', case when v_investido > 0 and v_leads > 0
      then round(v_investido / v_leads, 2) end,
    'cpl_engenheiro', case when v_investido > 0 and v_engs > 0
      then round(v_investido / v_engs, 2) end,
    'cpa', case when v_investido > 0 and v_compradores > 0
      then round(v_investido / v_compradores, 2) end,
    'cpa_engenheiro', case when v_investido > 0 and v_comp_eng > 0
      then round(v_investido / v_comp_eng, 2) end,

    -- ---- retorno
    'roas', case when v_investido > 0
      then round(v_receita / v_investido, 2) end,
    'roas_engenheiro', case when v_investido > 0
      then round(v_receita_eng / v_investido, 2) end,
    'receita_engenheiro', v_receita_eng,
    'pct_receita_engenheiro', case when v_receita > 0
      then round(100.0 * v_receita_eng / v_receita, 1) end,

    -- ---- metas
    'meta_faturamento', v_meta,
    'pct_da_meta', case when v_meta > 0
      then round(100.0 * v_receita / v_meta, 1) end,
    'meta_leads', v_meta_leads,
    'pct_meta_leads', case when v_meta_leads > 0
      then round(100.0 * v_leads / v_meta_leads, 1) end,

    -- ---- detalhamento
    'por_plataforma', coalesce(v_plataformas, '[]'::jsonb),
    'por_produto', coalesce(v_prods, '[]'::jsonb),
    'catalogo', coalesce(v_catalogo, '[]'::jsonb),
    'por_dia', coalesce(v_dias, '[]'::jsonb)
  );
end $$;

grant execute on function public.dash_resumo_lancamento(jsonb) to service_role;

select 'pronto' as status;
