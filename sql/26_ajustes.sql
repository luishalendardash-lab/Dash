-- =====================================================================
-- 26 — AJUSTES
--
-- Tudo que hoje só se muda por SQL passa a ter tela: imposto, taxas das
-- plataformas, metas do lançamento e contas do Meta.
--
-- Também traz um diagnóstico: o que está configurado, o que falta, e
-- quais webhooks falharam nos últimos dias.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. LER TUDO
-- ---------------------------------------------------------------------
create or replace function public.dash_ajustes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc dash.lancamentos%rowtype;
  v_config jsonb; v_plataformas jsonb; v_saude jsonb; v_lancs jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select * into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc.id is null then
    select * into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;

  -- configurações gerais
  select jsonb_object_agg(chave, valor) into v_config from dash.config;

  -- plataformas e suas taxas
  select jsonb_agg(jsonb_build_object(
    'slug', slug, 'nome', nome, 'inicial', inicial, 'cor', cor,
    'taxa_percentual', taxa_percentual, 'taxa_fixa', taxa_fixa,
    'ativa', ativa, 'ordem', ordem,
    'tem_venda', exists (select 1 from dash.vendas v where v.plataforma = plataformas.slug)
  ) order by ordem, nome)
  into v_plataformas from dash.plataformas;

  -- lançamentos, para trocar status e comparar
  select jsonb_agg(jsonb_build_object(
    'slug', slug, 'nome', nome, 'codigo', codigo, 'status', status,
    'criado_em', criado_em,
    'leads', (select count(*) from dash.inscricoes i where i.lancamento_id = lancamentos.id),
    'vendas', (select count(*) from dash.vendas v
               where v.lancamento_id = lancamentos.id and v.status = 'aprovada')
  ) order by criado_em desc)
  into v_lancs from dash.lancamentos;

  -- o que está de pé e o que não está
  select jsonb_build_object(
    'integracoes_ativas', (select count(*) from dash.integracoes where ativa),
    'webhooks_com_erro_7d', (
      select count(*) from dash.webhooks_raw
      where processado = false and recebido_em > now() - interval '7 days'
    ),
    'ultimos_erros', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'fonte', fonte, 'erro', left(coalesce(erro,'sem detalhe'), 160),
        'quando', recebido_em
      ) order by recebido_em desc), '[]'::jsonb)
      from (
        select fonte, erro, recebido_em from dash.webhooks_raw
        where processado = false and recebido_em > now() - interval '7 days'
        order by recebido_em desc limit 8
      ) e
    ),
    'leads_sem_anuncio', (
      select count(*) from dash.inscricoes
      where lancamento_id = v_lanc.id and meta_ad_id is null
    ),
    'vendas_sem_lead', (
      select count(*) from dash.vendas
      where lancamento_id = v_lanc.id and status = 'aprovada' and inscricao_id is null
    ),
    'quiz_perguntas', (
      select count(*) from dash.quiz_perguntas
      where lancamento_id = v_lanc.id and ativa
    ),
    'tem_grupo', (v_lanc.config->>'grupo_url') is not null,
    'contas_meta', jsonb_array_length(coalesce(v_lanc.config->'meta_contas','[]'::jsonb))
  ) into v_saude;

  return jsonb_build_object(
    'ok', true,
    'config', coalesce(v_config, '{}'::jsonb),
    'plataformas', coalesce(v_plataformas, '[]'::jsonb),
    'lancamentos', coalesce(v_lancs, '[]'::jsonb),
    'saude', v_saude,
    'lancamento', case when v_lanc.id is null then null else jsonb_build_object(
      'slug', v_lanc.slug, 'nome', v_lanc.nome, 'codigo', v_lanc.codigo,
      'status', v_lanc.status,
      'meta_leads', v_lanc.meta_leads,
      'investimento_planejado', v_lanc.investimento_planejado,
      'produto', v_lanc.produto,
      'captacao_inicio', v_lanc.captacao_inicio,
      'captacao_fim', v_lanc.captacao_fim,
      'carrinho_abre', v_lanc.carrinho_abre,
      'carrinho_fecha', v_lanc.carrinho_fecha,
      'meta_faturamento', v_lanc.meta_faturamento,
      'grupo_url', v_lanc.config->>'grupo_url',
      'meta_contas', coalesce(v_lanc.config->'meta_contas','[]'::jsonb)
    ) end
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. IMPOSTO E OUTRAS CONFIGURAÇÕES GERAIS
-- ---------------------------------------------------------------------
create or replace function public.salvar_config(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_chave text; v_valor jsonb; v_qtd int := 0;
begin
  for v_chave, v_valor in select * from jsonb_each(coalesce(p->'config','{}'::jsonb))
  loop
    insert into dash.config (chave, valor, atualizado_em)
    values (v_chave, v_valor, now())
    on conflict (chave) do update set
      valor = excluded.valor, atualizado_em = now();
    v_qtd := v_qtd + 1;
  end loop;
  return jsonb_build_object('ok', true, 'salvos', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 3. PLATAFORMAS
-- ---------------------------------------------------------------------
create or replace function public.salvar_plataforma(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_slug text;
begin
  v_slug := nullif(btrim(lower(p->>'slug')), '');
  if v_slug is null then
    return jsonb_build_object('ok', false, 'erro', 'informe a plataforma');
  end if;

  insert into dash.plataformas (slug, nome, inicial, cor, taxa_percentual, taxa_fixa, ativa, ordem)
  values (
    v_slug,
    coalesce(nullif(p->>'nome',''), initcap(v_slug)),
    coalesce(nullif(p->>'inicial',''), upper(left(v_slug,1))),
    coalesce(nullif(p->>'cor',''), '#666666'),
    coalesce(nullif(p->>'taxa_percentual','')::numeric, 0),
    coalesce(nullif(p->>'taxa_fixa','')::numeric, 0),
    coalesce((p->>'ativa')::boolean, true),
    coalesce(nullif(p->>'ordem','')::int, 99)
  )
  on conflict (slug) do update set
    nome = coalesce(nullif(excluded.nome,''), dash.plataformas.nome),
    inicial = excluded.inicial,
    cor = excluded.cor,
    taxa_percentual = excluded.taxa_percentual,
    taxa_fixa = excluded.taxa_fixa,
    ativa = excluded.ativa,
    ordem = excluded.ordem;

  return jsonb_build_object('ok', true, 'slug', v_slug);
end $$;

-- ---------------------------------------------------------------------
-- 4. LANÇAMENTO: metas, datas, grupo e contas do Meta
-- ---------------------------------------------------------------------
create or replace function public.salvar_lancamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_id uuid; v_contas jsonb;
begin
  select id into v_id from dash.lancamentos where slug = p->>'lancamento';
  if v_id is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  update dash.lancamentos set
    nome = coalesce(nullif(p->>'nome',''), nome),
    produto = coalesce(nullif(p->>'produto',''), produto),
    status = coalesce(nullif(p->>'status',''), status),
    meta_leads = coalesce(nullif(p->>'meta_leads','')::int, meta_leads),
    meta_faturamento = coalesce(
      nullif(p->>'meta_faturamento','')::numeric, meta_faturamento),
    investimento_planejado = coalesce(
      nullif(p->>'investimento_planejado','')::numeric, investimento_planejado),
    captacao_inicio = coalesce(nullif(p->>'captacao_inicio','')::timestamptz, captacao_inicio),
    captacao_fim = coalesce(nullif(p->>'captacao_fim','')::timestamptz, captacao_fim),
    carrinho_abre = coalesce(nullif(p->>'carrinho_abre','')::timestamptz, carrinho_abre),
    carrinho_fecha = coalesce(nullif(p->>'carrinho_fecha','')::timestamptz, carrinho_fecha)
  where id = v_id;

  -- link do grupo
  if p ? 'grupo_url' then
    update dash.lancamentos set
      config = coalesce(config,'{}'::jsonb)
               || jsonb_build_object('grupo_url', nullif(btrim(p->>'grupo_url'), ''))
    where id = v_id;
  end if;

  -- contas de anúncio: aceita lista ou texto separado por vírgula
  if p ? 'meta_contas' then
    if jsonb_typeof(p->'meta_contas') = 'array' then
      v_contas := p->'meta_contas';
    else
      select coalesce(jsonb_agg(btrim(x)), '[]'::jsonb) into v_contas
      from unnest(string_to_array(coalesce(p->>'meta_contas',''), ',')) as x
      where btrim(x) <> '';
    end if;

    update dash.lancamentos set
      config = coalesce(config,'{}'::jsonb) || jsonb_build_object('meta_contas', v_contas)
    where id = v_id;
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 5. LIMPEZA DOS DADOS DE TESTE
--    Apaga leads, vendas, eventos e anúncios de um lançamento, mantendo
--    a configuração: quiz, integrações, plataformas e o lançamento em si.
--    Exige confirmação explícita — é irreversível.
-- ---------------------------------------------------------------------
create or replace function public.zerar_lancamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_id uuid; v_slug text; v_leads int; v_vendas int;
begin
  if coalesce(p->>'confirmar','') <> 'ZERAR' then
    return jsonb_build_object('ok', false,
      'erro', 'para confirmar, envie confirmar: ZERAR');
  end if;

  select id, slug into v_id, v_slug
  from dash.lancamentos where slug = p->>'lancamento';
  if v_id is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select count(*) into v_leads from dash.inscricoes where lancamento_id = v_id;
  select count(*) into v_vendas from dash.vendas where lancamento_id = v_id;

  delete from dash.quiz_respostas where inscricao_id in (
    select id from dash.inscricoes where lancamento_id = v_id);
  delete from dash.eventos where inscricao_id in (
    select id from dash.inscricoes where lancamento_id = v_id);
  delete from dash.vendas where lancamento_id = v_id;
  delete from dash.inscricoes where lancamento_id = v_id;
  delete from dash.ads_insights where lancamento_id = v_id;
  delete from dash.ads_entidades where lancamento_id = v_id;

  -- pessoas que não sobraram em nenhum outro lançamento
  delete from dash.pessoas p2
  where not exists (select 1 from dash.inscricoes i where i.pessoa_id = p2.id)
    and not exists (select 1 from dash.vendas v where v.pessoa_id = p2.id);

  -- webhooks brutos de teste
  delete from dash.webhooks_raw where recebido_em < now();

  return jsonb_build_object('ok', true, 'lancamento', v_slug,
    'leads_apagados', v_leads, 'vendas_apagadas', v_vendas);
end $$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.dash_ajustes(jsonb), public.salvar_config(jsonb),
  public.salvar_plataforma(jsonb), public.salvar_lancamento(jsonb),
  public.zerar_lancamento(jsonb) from public, anon, authenticated;
grant execute on function public.dash_ajustes(jsonb), public.salvar_config(jsonb),
  public.salvar_plataforma(jsonb), public.salvar_lancamento(jsonb),
  public.zerar_lancamento(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

select public.dash_ajustes('{}'::jsonb) -> 'ok' as ajustes_ok;
