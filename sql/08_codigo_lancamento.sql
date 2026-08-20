-- =====================================================================
-- 08 — CÓDIGO DO LANÇAMENTO
--
-- A dash gera um código curto (ex: L2609). Você coloca esse código no
-- início do nome de toda campanha do lançamento, nas duas contas.
-- A sincronização passa a puxar só campanhas que começam com ele —
-- e junto os conjuntos e anúncios dessas campanhas.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. COLUNA
-- ---------------------------------------------------------------------
alter table dash.lancamentos
  add column if not exists codigo text;

create unique index if not exists ux_lancamento_codigo
  on dash.lancamentos (codigo) where codigo is not null;

-- ---------------------------------------------------------------------
-- 2. GERADOR — L + ano + mês, com letra extra se já existir
--    L2609, L2609B, L2609C...
-- ---------------------------------------------------------------------
create or replace function dash.gerar_codigo_lancamento(p_data date default current_date)
returns text language plpgsql as $$
declare base text; tentativa text; sufixos text[] := array['','B','C','D','E','F','G','H'];
        i int;
begin
  base := 'L' || to_char(p_data, 'YYMM');
  for i in 1..array_length(sufixos, 1) loop
    tentativa := base || sufixos[i];
    if not exists (select 1 from dash.lancamentos where codigo = tentativa) then
      return tentativa;
    end if;
  end loop;
  -- caso improvável de 8 lançamentos no mesmo mês
  return base || to_char(clock_timestamp(), 'SSMS');
end $$;

-- ---------------------------------------------------------------------
-- 3. CRIAR LANÇAMENTO PELA DASH
--    p: { nome, produto, captacao_inicio, carrinho_abre, carrinho_fecha,
--         meta_leads, investimento_planejado, meta_faturamento }
--    As contas de anúncio são herdadas do lançamento anterior — não faz
--    sentido redigitar todo mês o que nunca muda.
-- ---------------------------------------------------------------------
create or replace function public.criar_lancamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_codigo text; v_slug text; v_id uuid; v_contas jsonb; v_inicio date;
begin
  if nullif(btrim(coalesce(p->>'nome','')), '') is null then
    return jsonb_build_object('ok', false, 'erro', 'informe o nome do lancamento');
  end if;

  v_inicio := coalesce((p->>'captacao_inicio')::date, current_date);
  v_codigo := dash.gerar_codigo_lancamento(v_inicio);
  v_slug := lower(v_codigo);

  -- herda a configuração de contas do lançamento mais recente
  select coalesce(config->'meta_contas', '[]'::jsonb) into v_contas
  from dash.lancamentos
  where config ? 'meta_contas'
  order by criado_em desc limit 1;

  insert into dash.lancamentos (
    slug, codigo, nome, produto, status,
    captacao_inicio, captacao_fim, carrinho_abre, carrinho_fecha,
    meta_leads, meta_faturamento, investimento_planejado, config
  ) values (
    v_slug, v_codigo,
    p->>'nome',
    nullif(p->>'produto',''),
    coalesce(nullif(p->>'status',''), 'planejado'),
    (p->>'captacao_inicio')::timestamptz,
    (p->>'captacao_fim')::timestamptz,
    (p->>'carrinho_abre')::timestamptz,
    (p->>'carrinho_fecha')::timestamptz,
    nullif(p->>'meta_leads','')::int,
    nullif(p->>'meta_faturamento','')::numeric,
    nullif(p->>'investimento_planejado','')::numeric,
    jsonb_build_object('meta_contas', coalesce(v_contas, '[]'::jsonb))
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'slug', v_slug, 'codigo', v_codigo,
    'instrucao', 'Coloque ' || v_codigo || ' no início do nome de toda campanha deste lançamento.'
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.criar_lancamento(jsonb) from public, anon, authenticated;
grant execute on function public.criar_lancamento(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 5. CÓDIGO PARA O LANÇAMENTO QUE JÁ EXISTE
-- ---------------------------------------------------------------------
update dash.lancamentos
set codigo = coalesce(codigo, dash.gerar_codigo_lancamento(coalesce(captacao_inicio::date, current_date)))
where slug = 'lanc-2026-09';

-- limpa o que ficou de teste e o prefixo antigo, se houver
update dash.lancamentos
set config = (config - 'meta_account_id' - 'meta_prefixo' - 'meta_campanhas')
where slug = 'lanc-2026-09';

-- ---------------------------------------------------------------------
-- 6. LIMPEZA: métricas e entidades que entraram sem filtro
--    (a primeira sincronização trouxe a conta inteira)
-- ---------------------------------------------------------------------
delete from dash.ads_insights;
delete from dash.ads_entidades;

-- ---------------------------------------------------------------------
-- 7. CONFERE — anote o código que aparecer aqui
-- ---------------------------------------------------------------------
select slug, codigo, nome, status, config from dash.lancamentos;
