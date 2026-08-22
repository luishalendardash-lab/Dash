-- =====================================================================
-- 50 — O GRÁFICO SEGUE O LANÇAMENTO
--
-- A série diária mostrava sempre os últimos N dias. Num lançamento
-- histórico isso dá uma linha reta em zero: você olha março e o gráfico
-- desenha as últimas quatro semanas, onde não houve captação nenhuma.
--
-- Agora, quando o lançamento já acabou, a série cobre o período dele.
-- No lançamento em andamento, continua mostrando os últimos dias.
-- =====================================================================

set search_path = dash, public;

create or replace function public.dash_serie_diaria(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_status text; v_dias int;
  v_de date; v_ate date; v_res jsonb;
  v_primeiro date; v_ultimo date;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, status into v_lanc, v_status
    from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id, status into v_lanc, v_status from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then
    return jsonb_build_object('ok', true, 'dados', '[]'::jsonb);
  end if;

  v_dias := coalesce(nullif(p->>'dias','')::int, 30);

  -- onde os leads realmente estão
  select min(capturado_em)::date, max(capturado_em)::date
  into v_primeiro, v_ultimo
  from dash.inscricoes where lancamento_id = v_lanc;

  if v_primeiro is null then
    return jsonb_build_object('ok', true, 'dados', '[]'::jsonb);
  end if;

  -- lançamento encerrado, ou cuja captação terminou há mais de uma
  -- semana: mostra o período dele, não os últimos dias
  if v_ultimo < current_date - 7 then
    v_de := v_primeiro;
    v_ate := v_ultimo;
  else
    v_de := greatest(v_primeiro, current_date - v_dias);
    v_ate := current_date;
  end if;

  -- limita a 120 pontos: além disso o gráfico vira ruído
  if v_ate - v_de > 120 then v_de := v_ate - 120; end if;

  with dias as (
    select generate_series(v_de, v_ate, interval '1 day')::date as dia
  ),
  leads as (
    select capturado_em::date as dia,
           count(*) as leads,
           count(*) filter (where engenheiro) as engenheiros
    from dash.inscricoes
    where lancamento_id = v_lanc
      and capturado_em::date between v_de and v_ate
    group by 1
  ),
  gasto as (
    select data_ref as dia, round(sum(gasto), 2) as investido
    from dash.ads_insights
    where lancamento_id = v_lanc and data_ref between v_de and v_ate
    group by 1
  )
  select jsonb_agg(jsonb_build_object(
    'dia', d.dia,
    'leads', coalesce(l.leads, 0),
    'engenheiros', coalesce(l.engenheiros, 0),
    'investido', coalesce(g.investido, 0),
    'cpl', case when coalesce(g.investido, 0) > 0 and coalesce(l.leads, 0) > 0
      then round(g.investido / l.leads, 2) end
  ) order by d.dia)
  into v_res
  from dias d
  left join leads l on l.dia = d.dia
  left join gasto g on g.dia = d.dia;

  return jsonb_build_object(
    'ok', true,
    'de', v_de, 'ate', v_ate,
    'periodo_do_lancamento', v_ultimo < current_date - 7,
    'dados', coalesce(v_res, '[]'::jsonb)
  );
end $$;

grant execute on function public.dash_serie_diaria(jsonb) to service_role;

select 'pronto' as status;
