-- =====================================================================
-- 47 — RESULTADO DO LANÇAMENTO NA HOME
--
-- A Home mostra o faturamento do período (todas as plataformas, venha de
-- onde vier). Falta o que interessa no dia a dia do lançamento: quanto
-- ELE vendeu, com que atribuição e qual o retorno sobre o investido.
--
-- Este resumo junta as duas pontas — investimento e receita — que hoje
-- vivem em telas separadas.
-- =====================================================================

set search_path = dash, public;

create or replace function public.dash_resumo_lancamento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_nome text; v_meta numeric;
  v_investido numeric; v_res jsonb;
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

  select coalesce(round(sum(gasto), 2), 0) into v_investido
  from dash.ads_insights where lancamento_id = v_lanc;

  select jsonb_build_object(
    'ok', true,
    'lancamento', v_nome,
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
    -- as duas pontas juntas: é aqui que se sabe se o lançamento pagou
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
                 / v_meta, 1) end
  ) into v_res
  from dash.vendas where lancamento_id = v_lanc;

  return v_res;
end $$;

revoke all on function public.dash_resumo_lancamento(jsonb) from public, anon, authenticated;
grant execute on function public.dash_resumo_lancamento(jsonb) to service_role;

select jsonb_pretty(public.dash_resumo_lancamento('{}'::jsonb));
