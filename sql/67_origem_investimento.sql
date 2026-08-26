-- =====================================================================
-- 67 — UMA ORIGEM POR LANÇAMENTO
--
-- O investimento pode entrar por quatro caminhos: CSV de campanhas,
-- sincronização automática, busca por ID de anúncio e lançamento manual.
-- Cada um grava com um identificador próprio, então eles SOMAM em vez de
-- substituir — e o investido aparece dobrado.
--
-- Agora a sincronização automática limpa as outras origens do mesmo
-- lançamento antes de gravar. Ela é a mais confiável: vem da API, cobre
-- todas as campanhas e roda sozinha.
--
-- Quem quiser continuar com o CSV pode: basta não usar o botão.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 0. DE QUAL CAMINHO O REGISTRO VEIO
--    O prefixo do ad_id diz a origem; isolar aqui evita repetir o mesmo
--    CASE em cada consulta.
-- ---------------------------------------------------------------------
create or replace function dash.origem_insight(p_ad_id text)
returns text language sql immutable as $$
  select case
    when p_ad_id like 'csv-%'   then 'csv'
    when p_ad_id like 'auto-%'  then 'auto'
    when p_ad_id like 'geral-%' then 'manual'
    when p_ad_id ~ '^[0-9]+$'   then 'id'
    else 'outra'
  end;
$$;

-- ---------------------------------------------------------------------
-- 1. DE ONDE VEIO CADA REAL
-- ---------------------------------------------------------------------
create or replace function public.investimento_por_origem(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'lancamento', nome, 'slug', slug, 'origem', origem,
    'registros', n, 'gasto', gasto
  ) order by nome, gasto desc)
  into v_res
  from (
    select nome, slug,
      case chave
        when 'csv' then 'CSV de campanhas'
        when 'auto' then 'Sincronização automática'
        when 'manual' then 'Total lançado à mão'
        when 'id' then 'Busca por ID de anúncio'
        else 'Outra'
      end as origem,
      n, gasto
    from (
      -- o agrupamento acontece sobre a chave, não sobre o rótulo:
      -- agrupar por expressão posicional quebra quando a consulta cresce
      select l.nome, l.slug,
             dash.origem_insight(a.ad_id) as chave,
             count(*) as n,
             round(sum(a.gasto), 2) as gasto
      from dash.ads_insights a
      join dash.lancamentos l on l.id = a.lancamento_id
      group by l.nome, l.slug, dash.origem_insight(a.ad_id)
    ) base
  ) t;

  return jsonb_build_object(
    'ok', true,
    'origens', coalesce(v_res, '[]'::jsonb),
    'total', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights),
    'duplicado', (
      -- lançamento com mais de uma origem está somando duas contagens
      -- do mesmo gasto: é o sintoma que interessa avisar
      select coalesce(jsonb_agg(nome order by nome), '[]'::jsonb)
      from (
        select l.nome
        from dash.ads_insights a
        join dash.lancamentos l on l.id = a.lancamento_id
        group by l.nome
        having count(distinct dash.origem_insight(a.ad_id)) > 1
      ) d
    )
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. LIMPAR UMA ORIGEM
--    p: { origem: 'csv' | 'auto' | 'manual' | 'id' | 'tudo', lancamento }
-- ---------------------------------------------------------------------
create or replace function public.limpar_investimento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_origem text; v_lanc uuid; v_padrao text; v_qtd int; v_valor numeric;
begin
  v_origem := coalesce(nullif(p->>'origem',''), 'tudo');

  if nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  v_padrao := case v_origem
    when 'csv' then 'csv-%'
    when 'auto' then 'auto-%'
    when 'manual' then 'geral-%'
    else null
  end;

  select count(*), coalesce(round(sum(gasto),2),0) into v_qtd, v_valor
  from dash.ads_insights a
  where (v_lanc is null or a.lancamento_id = v_lanc)
    and (v_padrao is null or a.ad_id like v_padrao)
    and (v_origem <> 'id' or a.ad_id ~ '^[0-9]+$');

  delete from dash.ads_insights a
  where (v_lanc is null or a.lancamento_id = v_lanc)
    and (v_padrao is null or a.ad_id like v_padrao)
    and (v_origem <> 'id' or a.ad_id ~ '^[0-9]+$');

  -- entidade que ficou sem nenhum insight não serve para nada
  delete from dash.ads_entidades e
  where not exists (select 1 from dash.ads_insights i where i.ad_id = e.id);

  return jsonb_build_object('ok', true, 'origem', v_origem,
                            'registros', v_qtd, 'gasto_removido', v_valor);
end $$;

-- ---------------------------------------------------------------------
-- 3. A SINCRONIZAÇÃO PASSA A SUBSTITUIR, NÃO SOMAR
-- ---------------------------------------------------------------------
create or replace function public.ingest_investimento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_item jsonb; v_data date; v_lanc uuid; v_slug text; v_chave text;
  v_gasto numeric; v_so_cap boolean; v_nome text;
  v_qtd int := 0; v_fora int := 0; v_sem_data int := 0;
  v_total numeric := 0; v_por_lanc jsonb := '{}'::jsonb;
  v_ignoradas jsonb := '[]'::jsonb; v_lancs uuid[] := '{}';
  v_limpos int := 0;
begin
  v_so_cap := coalesce((p->>'so_captacao')::boolean, true);

  for v_item in select * from jsonb_array_elements(coalesce(p->'campanhas','[]'::jsonb))
  loop
    v_nome := coalesce(nullif(btrim(v_item->>'nome'),''), v_item->>'id');
    v_gasto := coalesce(dash.valor_para_numero(v_item->>'gasto'), 0);
    if v_gasto <= 0 then continue; end if;

    if v_so_cap and upper(translate(v_nome, 'ÇÃÁÉÍÓÚÂÊÔÕ', 'CAAEIOUAEOO'))
       not like '%CAPTACAO%' then
      v_fora := v_fora + 1;
      continue;
    end if;

    v_data := coalesce(dash.data_do_nome(v_nome), nullif(v_item->>'dia','')::date);
    if v_data is null then
      v_sem_data := v_sem_data + 1;
      v_ignoradas := v_ignoradas || jsonb_build_array(
        jsonb_build_object('nome', v_nome, 'gasto', v_gasto));
      continue;
    end if;

    v_lanc := dash.lancamento_na_data(v_data::timestamptz);
    if v_lanc is null then
      v_sem_data := v_sem_data + 1;
      continue;
    end if;

    -- Na primeira vez que um lançamento aparece neste lote, apagamos o
    -- que veio de outras origens. Sem isto o CSV e a API se somam e o
    -- investido aparece dobrado.
    if not (v_lanc = any(v_lancs)) then
      v_lancs := v_lancs || v_lanc;

      with removidos as (
        delete from dash.ads_insights
        where lancamento_id = v_lanc
          and (ad_id like 'csv-%' or ad_id like 'geral-%')
        returning 1
      )
      select v_limpos + count(*) into v_limpos from removidos;
    end if;

    v_chave := 'auto-' || coalesce(nullif(v_item->>'id',''), md5(v_nome));

    insert into dash.ads_entidades (id, lancamento_id, nivel, nome, conta_id)
    values (v_chave, v_lanc, 'ad', v_nome,
            coalesce(nullif(v_item->>'conta',''), 'meta'))
    on conflict (id) do update set
      nome = excluded.nome, lancamento_id = excluded.lancamento_id;

    insert into dash.ads_insights
      (ad_id, lancamento_id, data_ref, gasto, impressoes, cliques)
    values (
      v_chave, v_lanc, coalesce(nullif(v_item->>'dia','')::date, v_data), v_gasto,
      coalesce(nullif(v_item->>'impressoes','')::bigint, 0),
      coalesce(nullif(v_item->>'cliques','')::bigint, 0)
    )
    on conflict (ad_id, data_ref) do update set
      gasto = excluded.gasto,
      impressoes = excluded.impressoes,
      cliques = excluded.cliques,
      lancamento_id = excluded.lancamento_id;

    select slug into v_slug from dash.lancamentos where id = v_lanc;
    v_por_lanc := jsonb_set(v_por_lanc, array[v_slug],
      to_jsonb(round(coalesce((v_por_lanc->>v_slug)::numeric, 0) + v_gasto, 2)));

    v_qtd := v_qtd + 1;
    v_total := v_total + v_gasto;
  end loop;

  delete from dash.ads_entidades e
  where not exists (select 1 from dash.ads_insights i where i.ad_id = e.id);

  return jsonb_build_object(
    'ok', true, 'campanhas', v_qtd, 'gasto', round(v_total, 2),
    'fora_de_captacao', v_fora, 'sem_data_no_nome', v_sem_data,
    'substituidos', v_limpos,
    'ignoradas', v_ignoradas, 'por_lancamento', v_por_lanc
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.investimento_por_origem(jsonb), public.limpar_investimento(jsonb)
  from public, anon, authenticated;
grant execute on function public.investimento_por_origem(jsonb),
  public.limpar_investimento(jsonb), public.ingest_investimento(jsonb) to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 5. VEJA COMO ESTÁ AGORA
-- ---------------------------------------------------------------------
select jsonb_pretty(public.investimento_por_origem('{}'::jsonb));
