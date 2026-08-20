-- =====================================================================
-- 09 — CÓDIGO EDITÁVEL
-- A dash continua sugerindo, mas o admin pode trocar na criação.
-- Regras: 2 a 20 caracteres, letras, números, hífen e underscore,
-- sempre em maiúsculas, e único entre os lançamentos.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. VALIDAÇÃO
--    Espaço no código quebraria o filtro por prefixo no nome da campanha.
-- ---------------------------------------------------------------------
create or replace function dash.normalizar_codigo(p_codigo text)
returns text language plpgsql immutable as $$
declare c text;
begin
  if p_codigo is null then return null; end if;
  c := upper(btrim(p_codigo));
  if c = '' then return null; end if;
  if c !~ '^[A-Z0-9_-]{2,20}$' then
    raise exception 'codigo invalido: use de 2 a 20 caracteres, apenas letras, numeros, hifen ou underscore (sem espaco)';
  end if;
  return c;
end $$;

-- ---------------------------------------------------------------------
-- 2. SUGESTÃO — usada pela tela antes de criar
-- ---------------------------------------------------------------------
create or replace function public.sugerir_codigo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_data date;
begin
  v_data := coalesce((p->>'captacao_inicio')::date, current_date);
  return jsonb_build_object('ok', true, 'codigo', dash.gerar_codigo_lancamento(v_data));
end $$;

-- ---------------------------------------------------------------------
-- 3. CRIAR LANÇAMENTO — agora aceita código informado
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

  -- código do admin vence; sem ele, a dash gera
  begin
    v_codigo := dash.normalizar_codigo(p->>'codigo');
  exception when others then
    return jsonb_build_object('ok', false, 'erro', SQLERRM);
  end;

  if v_codigo is null then
    v_codigo := dash.gerar_codigo_lancamento(v_inicio);
  elsif exists (select 1 from dash.lancamentos where codigo = v_codigo) then
    return jsonb_build_object('ok', false,
      'erro', 'o codigo ' || v_codigo || ' ja esta em uso por outro lancamento');
  end if;

  v_slug := lower(v_codigo);
  if exists (select 1 from dash.lancamentos where slug = v_slug) then
    v_slug := v_slug || '-' || to_char(clock_timestamp(), 'SSMS');
  end if;

  select coalesce(config->'meta_contas', '[]'::jsonb) into v_contas
  from dash.lancamentos where config ? 'meta_contas'
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
    'instrucao', 'Coloque ' || v_codigo || ' no inicio do nome de toda campanha deste lancamento.'
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. TROCAR O CÓDIGO DE UM LANÇAMENTO QUE JÁ EXISTE
--    Trocar depois exige renomear as campanhas no Meta — por isso a
--    resposta devolve quantas campanhas ficarão órfãs.
-- ---------------------------------------------------------------------
create or replace function public.alterar_codigo(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_id uuid; v_antigo text; v_novo text; v_campanhas int;
begin
  select id, codigo into v_id, v_antigo
  from dash.lancamentos where slug = p->>'lancamento';
  if v_id is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  begin
    v_novo := dash.normalizar_codigo(p->>'codigo');
  exception when others then
    return jsonb_build_object('ok', false, 'erro', SQLERRM);
  end;

  if v_novo is null then
    return jsonb_build_object('ok', false, 'erro', 'informe o novo codigo');
  end if;
  if exists (select 1 from dash.lancamentos where codigo = v_novo and id <> v_id) then
    return jsonb_build_object('ok', false, 'erro', 'codigo ja em uso');
  end if;

  select count(*) into v_campanhas
  from dash.ads_entidades
  where lancamento_id = v_id and nivel = 'campaign';

  update dash.lancamentos set codigo = v_novo where id = v_id;

  return jsonb_build_object(
    'ok', true, 'de', v_antigo, 'para', v_novo,
    'campanhas_para_renomear', v_campanhas,
    'aviso', case when v_campanhas > 0
      then 'renomeie essas campanhas no Meta para comecar com ' || v_novo ||
           ', senao elas somem da dash na proxima sincronizacao'
      else 'nenhuma campanha sincronizada ainda' end
  );
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.sugerir_codigo(jsonb), public.criar_lancamento(jsonb),
  public.alterar_codigo(jsonb) from public, anon, authenticated;
grant execute on function public.sugerir_codigo(jsonb), public.criar_lancamento(jsonb),
  public.alterar_codigo(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 6. TESTE
-- ---------------------------------------------------------------------
select public.sugerir_codigo('{}'::jsonb);
select dash.normalizar_codigo('  l2609-b ');   -- L2609-B
