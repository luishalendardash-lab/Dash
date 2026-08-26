-- =====================================================================
-- 62 — CONTAS DE ANÚNCIO GLOBAIS
--
-- As contas do Meta estavam guardadas dentro de cada lançamento. Isso
-- obriga a repetir a configuração todo mês e, se alguém esquece, a
-- sincronização de investimento não acha conta nenhuma — foi o que
-- aconteceu.
--
-- As contas são do cliente, não do lançamento. Agora ficam num lugar só
-- e valem para todos. O campo por lançamento continua funcionando, para
-- o caso de um lançamento rodar numa conta diferente.
-- =====================================================================

set search_path = dash, public;

create table if not exists dash.config_geral (
  chave      text primary key,
  valor      jsonb not null,
  atualizado timestamptz not null default now()
);

alter table dash.config_geral enable row level security;

-- ---------------------------------------------------------------------
-- 1. SALVAR AS CONTAS
--    p: { contas: ['act_123', 'act_456'] }
-- ---------------------------------------------------------------------
create or replace function public.salvar_contas_meta(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_contas jsonb;
begin
  -- aceita lista ou texto separado por vírgula, e normaliza o prefixo
  if jsonb_typeof(p->'contas') = 'array' then
    select jsonb_agg(
      case when v like 'act_%' then v else 'act_' || regexp_replace(v, '\D', '', 'g') end
    ) into v_contas
    from jsonb_array_elements_text(p->'contas') v
    where btrim(v) <> '';
  else
    select jsonb_agg(
      case when btrim(v) like 'act_%' then btrim(v)
           else 'act_' || regexp_replace(v, '\D', '', 'g') end
    ) into v_contas
    from unnest(string_to_array(coalesce(p->>'contas',''), ',')) v
    where btrim(v) <> '';
  end if;

  insert into dash.config_geral (chave, valor, atualizado)
  values ('meta_contas', coalesce(v_contas, '[]'::jsonb), now())
  on conflict (chave) do update set valor = excluded.valor, atualizado = now();

  return jsonb_build_object('ok', true, 'contas', coalesce(v_contas, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 2. LER
-- ---------------------------------------------------------------------
create or replace function public.contas_meta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_geral jsonb; v_por_lanc jsonb;
begin
  select valor into v_geral from dash.config_geral where chave = 'meta_contas';

  select coalesce(jsonb_agg(distinct c), '[]'::jsonb) into v_por_lanc
  from dash.lancamentos l,
       jsonb_array_elements_text(
         case when jsonb_typeof(l.config->'meta_contas') = 'array'
              then l.config->'meta_contas' else '[]'::jsonb end) c;

  return jsonb_build_object(
    'ok', true,
    'contas', coalesce(nullif(v_geral, '[]'::jsonb), v_por_lanc, '[]'::jsonb),
    'geral', coalesce(v_geral, '[]'::jsonb),
    'dos_lancamentos', v_por_lanc
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. A SINCRONIZAÇÃO PASSA A USAR AS GLOBAIS
-- ---------------------------------------------------------------------
create or replace function public.periodo_investimento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_de date; v_ate date; v_contas jsonb;
begin
  if nullif(p->>'de','') is not null then
    v_de := (p->>'de')::date;
    v_ate := coalesce(nullif(p->>'ate','')::date, current_date);
  else
    select min(capturado_em)::date into v_de from dash.inscricoes;
    v_de := coalesce(v_de, current_date - 90);
    v_ate := current_date;
  end if;

  if v_ate - v_de > 400 then v_de := v_ate - 400; end if;

  -- ordem: a conta global vale para tudo; a do lançamento é exceção
  select valor into v_contas from dash.config_geral where chave = 'meta_contas';

  if v_contas is null or v_contas = '[]'::jsonb then
    select coalesce(jsonb_agg(distinct c), '[]'::jsonb) into v_contas
    from dash.lancamentos l,
         jsonb_array_elements_text(
           case when jsonb_typeof(l.config->'meta_contas') = 'array'
                then l.config->'meta_contas' else '[]'::jsonb end) c;
  end if;

  return jsonb_build_object(
    'ok', true, 'de', v_de, 'ate', v_ate,
    'contas', coalesce(v_contas, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. AS OUTRAS BUSCAS TAMBÉM
-- ---------------------------------------------------------------------
create or replace function public.campanhas_escolhidas(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_ids jsonb; v_de date; v_ate date; v_contas jsonb;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select jsonb_agg(id) into v_ids
  from dash.ads_candidatas where lancamento_id = v_lanc and escolhida;

  select
    percentile_disc(0.02) within group (order by capturado_em)::date - 3,
    percentile_disc(0.98) within group (order by capturado_em)::date + 3
  into v_de, v_ate
  from dash.inscricoes
  where lancamento_id = v_lanc and capturado_em < now() - interval '1 day';

  if v_ate - v_de > 90 then v_ate := v_de + 90; end if;

  select valor into v_contas from dash.config_geral where chave = 'meta_contas';
  if v_contas is null or v_contas = '[]'::jsonb then
    select coalesce(config->'meta_contas', '[]'::jsonb) into v_contas
    from dash.lancamentos where id = v_lanc;
  end if;

  return jsonb_build_object('ok', true,
    'ids', coalesce(v_ids, '[]'::jsonb), 'de', v_de, 'ate', v_ate,
    'contas', coalesce(v_contas, '[]'::jsonb));
end $$;

create or replace function public.ads_para_buscar(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_ids jsonb; v_de date; v_ate date; v_contas jsonb;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select jsonb_agg(distinct i.meta_ad_id) into v_ids
  from dash.inscricoes i
  where i.lancamento_id = v_lanc
    and i.meta_ad_id ~ '^[0-9]+$'
    and (coalesce((p->>'refazer')::boolean, false)
         or not exists (select 1 from dash.ads_insights ai
                        where ai.ad_id = i.meta_ad_id));

  select
    percentile_disc(0.02) within group (order by capturado_em)::date - 3,
    percentile_disc(0.98) within group (order by capturado_em)::date + 3
  into v_de, v_ate
  from dash.inscricoes
  where lancamento_id = v_lanc and capturado_em < now() - interval '1 day';

  if v_ate - v_de > 90 then v_ate := v_de + 90; end if;

  select valor into v_contas from dash.config_geral where chave = 'meta_contas';
  if v_contas is null or v_contas = '[]'::jsonb then
    select coalesce(config->'meta_contas', '[]'::jsonb) into v_contas
    from dash.lancamentos where id = v_lanc;
  end if;

  return jsonb_build_object('ok', true,
    'ad_ids', coalesce(v_ids, '[]'::jsonb), 'de', v_de, 'ate', v_ate,
    'contas', coalesce(v_contas, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. APROVEITA O QUE JÁ ESTÁ NOS LANÇAMENTOS
--    Se algum lançamento tinha contas, elas viram as globais.
-- ---------------------------------------------------------------------
do $bloco$
declare v_contas jsonb;
begin
  if exists (select 1 from dash.config_geral where chave = 'meta_contas') then
    return;
  end if;

  select coalesce(jsonb_agg(distinct c), '[]'::jsonb) into v_contas
  from dash.lancamentos l,
       jsonb_array_elements_text(
         case when jsonb_typeof(l.config->'meta_contas') = 'array'
              then l.config->'meta_contas' else '[]'::jsonb end) c;

  if v_contas <> '[]'::jsonb then
    insert into dash.config_geral (chave, valor) values ('meta_contas', v_contas);
    raise notice 'contas aproveitadas dos lancamentos: %', v_contas;
  end if;
end $bloco$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.salvar_contas_meta(jsonb), public.contas_meta(jsonb)
  from public, anon, authenticated;
grant execute on function public.salvar_contas_meta(jsonb), public.contas_meta(jsonb),
  public.periodo_investimento(jsonb), public.campanhas_escolhidas(jsonb),
  public.ads_para_buscar(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

select jsonb_pretty(public.contas_meta('{}'::jsonb));
