-- =====================================================================
-- 27 — CUSTOS E IMPOSTOS
--
-- Antes existia um único imposto fixo. Agora dá para cadastrar quantas
-- deduções quiser, de três tipos:
--
--   percentual  — % sobre a receita bruta (imposto, coprodução, comissão)
--   por_venda   — R$ por venda (taxa de gateway, custo de entrega)
--   fixo        — R$ no período (ferramentas, equipe)
--
-- A ordem importa: as taxas da plataforma saem primeiro, porque já vêm
-- descontadas no que ela repassa. Depois os percentuais, sobre o bruto.
-- Somar percentuais sobre valores já líquidos daria um número menor e
-- errado.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. TABELA
-- ---------------------------------------------------------------------
create table if not exists dash.custos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  tipo        text not null default 'percentual',   -- percentual | por_venda | fixo
  valor       numeric(14,2) not null default 0,
  aplica_em   text not null default 'tudo',          -- tudo | plataforma | produto
  alvo        text,                                  -- slug da plataforma ou chave do produto
  ativo       boolean not null default true,
  observacao  text,
  ordem       int not null default 10,
  criado_em   timestamptz not null default now()
);

alter table dash.custos enable row level security;
create index if not exists ix_custos_ativo on dash.custos (ativo, ordem);

-- traz o imposto que já estava em config, para não perder a configuração
insert into dash.custos (nome, tipo, valor, ordem, observacao)
select 'Imposto', 'percentual',
       coalesce((valor)::text::numeric, 0), 1,
       'migrado da configuração antiga'
from dash.config
where chave = 'imposto_percentual'
  and coalesce((valor)::text::numeric, 0) > 0
  and not exists (select 1 from dash.custos where nome = 'Imposto');

-- ---------------------------------------------------------------------
-- 2. SALVAR E APAGAR
-- ---------------------------------------------------------------------
create or replace function public.salvar_custo(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_id uuid; v_tipo text;
begin
  v_tipo := coalesce(nullif(p->>'tipo',''), 'percentual');
  if v_tipo not in ('percentual','por_venda','fixo') then
    return jsonb_build_object('ok', false, 'erro', 'tipo invalido');
  end if;
  if nullif(btrim(p->>'nome'), '') is null then
    return jsonb_build_object('ok', false, 'erro', 'de um nome ao custo');
  end if;

  if p ? 'id' and nullif(p->>'id','') is not null then
    update dash.custos set
      nome = btrim(p->>'nome'),
      tipo = v_tipo,
      valor = coalesce(nullif(p->>'valor','')::numeric, 0),
      aplica_em = coalesce(nullif(p->>'aplica_em',''), 'tudo'),
      alvo = nullif(p->>'alvo',''),
      ativo = coalesce((p->>'ativo')::boolean, true),
      observacao = p->>'observacao',
      ordem = coalesce(nullif(p->>'ordem','')::int, ordem)
    where id = (p->>'id')::uuid
    returning id into v_id;
  else
    insert into dash.custos (nome, tipo, valor, aplica_em, alvo, ativo, observacao, ordem)
    values (
      btrim(p->>'nome'), v_tipo,
      coalesce(nullif(p->>'valor','')::numeric, 0),
      coalesce(nullif(p->>'aplica_em',''), 'tudo'),
      nullif(p->>'alvo',''),
      coalesce((p->>'ativo')::boolean, true),
      p->>'observacao',
      coalesce(nullif(p->>'ordem','')::int,
               (select coalesce(max(ordem),0)+1 from dash.custos))
    )
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.apagar_custo(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
begin
  delete from dash.custos where id = (p->>'id')::uuid;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 3. RECEITA COM AS DEDUÇÕES
-- ---------------------------------------------------------------------
create or replace function public.dash_receita(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_inicio timestamptz; v_fim timestamptz;
  v_filtro text[];
  v_linhas jsonb; v_produtos jsonb; v_deducoes jsonb;
  v_bruto numeric := 0; v_apos_plataforma numeric := 0;
  v_itens int := 0; v_pago numeric := 0;
  v_total_deducoes numeric := 0; v_liquido numeric := 0;
begin
  v_inicio := coalesce((p->>'inicio')::timestamptz, date_trunc('month', now()));
  v_fim    := coalesce((p->>'fim')::timestamptz, now() + interval '1 day');

  select array_agg(value) into v_filtro
  from jsonb_array_elements_text(coalesce(p->'produtos','[]'::jsonb));
  if v_filtro is not null and array_length(v_filtro, 1) is null then v_filtro := null; end if;

  with vendas_filtradas as (
    select v.*, coalesce(dash.chave_produto(v.produto), '(sem produto)') as pchave
    from dash.vendas v
    where v.status = 'aprovada'
      and v.ocorreu_em >= v_inicio and v.ocorreu_em < v_fim
      and (v_filtro is null
           or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro))
  ),
  base as (
    select
      vf.plataforma,
      count(*) as itens,
      sum(vf.valor_bruto) as bruto,
      sum(
        case when vf.valor_liquido > 0 then vf.valor_liquido
             else greatest(0, vf.valor_bruto
                  - (vf.valor_bruto * coalesce(pl.taxa_percentual,0) / 100)
                  - coalesce(pl.taxa_fixa,0))
        end
      ) as apos_plataforma,
      sum(case when vf.plataforma = 'tmb'
               then coalesce(vf.valor_recebido, 0) else vf.valor_bruto end) as pago
    from vendas_filtradas vf
    left join dash.plataformas pl on pl.slug = vf.plataforma
    group by vf.plataforma
  ),
  porproduto as (
    select vf.pchave, min(vf.produto) as nome, count(*) as itens,
           sum(vf.valor_bruto) as bruto, count(distinct vf.plataforma) as plataformas
    from vendas_filtradas vf group by vf.pchave
  )
  select
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', b.plataforma,
        'nome', coalesce(pl.nome, initcap(b.plataforma)),
        'inicial', coalesce(pl.inicial, upper(left(b.plataforma,1))),
        'cor', coalesce(pl.cor, '#666666'),
        'itens', b.itens,
        'bruto', round(b.bruto, 2),
        'liquido', round(b.apos_plataforma, 2),
        'pago', round(b.pago, 2),
        'parcelado', b.plataforma = 'tmb'
      ) order by b.bruto desc)
      from base b left join dash.plataformas pl on pl.slug = b.plataforma
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'chave', pp.pchave, 'nome', coalesce(pp.nome, '(sem produto)'),
        'vendas', pp.itens, 'receita', round(pp.bruto, 2),
        'ticket', round(pp.bruto / nullif(pp.itens,0), 2),
        'plataformas', pp.plataformas
      ) order by pp.bruto desc)
      from porproduto pp
    ), '[]'::jsonb),
    coalesce((select sum(bruto) from base), 0),
    coalesce((select sum(apos_plataforma) from base), 0),
    coalesce((select sum(itens) from base), 0),
    coalesce((select sum(pago) from base), 0)
  into v_linhas, v_produtos, v_bruto, v_apos_plataforma, v_itens, v_pago;

  -- deduções cadastradas, calculadas sobre o BRUTO
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'nome', nome, 'tipo', tipo, 'valor', valor,
      'observacao', observacao,
      'total', round(
        case tipo
          when 'percentual' then v_bruto * valor / 100
          when 'por_venda'  then v_itens * valor
          else valor
        end, 2)
    ) order by ordem, nome), '[]'::jsonb),
    coalesce(sum(
      case tipo
        when 'percentual' then v_bruto * valor / 100
        when 'por_venda'  then v_itens * valor
        else valor
      end
    ), 0)
  into v_deducoes, v_total_deducoes
  from dash.custos where ativo;

  -- a taxa da plataforma já saiu; agora saem as deduções
  v_liquido := greatest(0, v_apos_plataforma - v_total_deducoes);

  return jsonb_build_object(
    'ok', true,
    'inicio', v_inicio, 'fim', v_fim,
    'plataformas', v_linhas,
    'produtos', v_produtos,
    'deducoes', v_deducoes,
    'filtrado', v_filtro is not null,
    'total_bruto', round(v_bruto, 2),
    'apos_plataforma', round(v_apos_plataforma, 2),
    'taxas_plataforma', round(v_bruto - v_apos_plataforma, 2),
    'total_deducoes', round(v_total_deducoes, 2),
    'total_liquido', round(v_liquido, 2),
    'total_itens', v_itens,
    'total_pago', round(v_pago, 2),
    -- mantido para compatibilidade com quem lia esse campo
    'imposto_percentual', coalesce((
      select valor from dash.custos
      where ativo and tipo = 'percentual' and lower(nome) like '%imposto%' limit 1
    ), 0)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. AJUSTES DEVOLVE OS CUSTOS
-- ---------------------------------------------------------------------
create or replace function public.dash_ajustes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc dash.lancamentos%rowtype;
  v_config jsonb; v_plataformas jsonb; v_saude jsonb; v_lancs jsonb; v_custos jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select * into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc.id is null then
    select * into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;

  select jsonb_object_agg(chave, valor) into v_config from dash.config;

  select jsonb_agg(jsonb_build_object(
    'id', id, 'nome', nome, 'tipo', tipo, 'valor', valor,
    'ativo', ativo, 'observacao', observacao, 'ordem', ordem
  ) order by ordem, nome) into v_custos from dash.custos;

  select jsonb_agg(jsonb_build_object(
    'slug', slug, 'nome', nome, 'inicial', inicial, 'cor', cor,
    'taxa_percentual', taxa_percentual, 'taxa_fixa', taxa_fixa,
    'ativa', ativa, 'ordem', ordem,
    'tem_venda', exists (select 1 from dash.vendas v where v.plataforma = plataformas.slug)
  ) order by ordem, nome)
  into v_plataformas from dash.plataformas;

  select jsonb_agg(jsonb_build_object(
    'slug', slug, 'nome', nome, 'codigo', codigo, 'status', status,
    'criado_em', criado_em,
    'leads', (select count(*) from dash.inscricoes i where i.lancamento_id = lancamentos.id),
    'vendas', (select count(*) from dash.vendas v
               where v.lancamento_id = lancamentos.id and v.status = 'aprovada')
  ) order by criado_em desc)
  into v_lancs from dash.lancamentos;

  select jsonb_build_object(
    'integracoes_ativas', (select count(*) from dash.integracoes where ativa),
    'webhooks_com_erro_7d', (
      select count(*) from dash.webhooks_raw
      where processado = false and recebido_em > now() - interval '7 days'),
    'ultimos_erros', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'fonte', fonte, 'erro', left(coalesce(erro,'sem detalhe'), 160), 'quando', recebido_em
      ) order by recebido_em desc), '[]'::jsonb)
      from (
        select fonte, erro, recebido_em from dash.webhooks_raw
        where processado = false and recebido_em > now() - interval '7 days'
        order by recebido_em desc limit 8
      ) e),
    'leads_sem_anuncio', (
      select count(*) from dash.inscricoes
      where lancamento_id = v_lanc.id and meta_ad_id is null),
    'vendas_sem_lead', (
      select count(*) from dash.vendas
      where lancamento_id = v_lanc.id and status = 'aprovada' and inscricao_id is null),
    'quiz_perguntas', (
      select count(*) from dash.quiz_perguntas
      where lancamento_id = v_lanc.id and ativa),
    'tem_grupo', (v_lanc.config->>'grupo_url') is not null,
    'contas_meta', jsonb_array_length(coalesce(v_lanc.config->'meta_contas','[]'::jsonb))
  ) into v_saude;

  return jsonb_build_object(
    'ok', true,
    'config', coalesce(v_config, '{}'::jsonb),
    'custos', coalesce(v_custos, '[]'::jsonb),
    'plataformas', coalesce(v_plataformas, '[]'::jsonb),
    'lancamentos', coalesce(v_lancs, '[]'::jsonb),
    'saude', v_saude,
    'lancamento', case when v_lanc.id is null then null else jsonb_build_object(
      'slug', v_lanc.slug, 'nome', v_lanc.nome, 'codigo', v_lanc.codigo,
      'status', v_lanc.status, 'produto', v_lanc.produto,
      'meta_leads', v_lanc.meta_leads,
      'meta_faturamento', v_lanc.meta_faturamento,
      'investimento_planejado', v_lanc.investimento_planejado,
      'captacao_inicio', v_lanc.captacao_inicio,
      'captacao_fim', v_lanc.captacao_fim,
      'carrinho_abre', v_lanc.carrinho_abre,
      'carrinho_fecha', v_lanc.carrinho_fecha,
      'grupo_url', v_lanc.config->>'grupo_url',
      'meta_contas', coalesce(v_lanc.config->'meta_contas','[]'::jsonb)
    ) end
  );
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.salvar_custo(jsonb), public.apagar_custo(jsonb)
  from public, anon, authenticated;
grant execute on function public.salvar_custo(jsonb), public.apagar_custo(jsonb),
  public.dash_receita(jsonb), public.dash_ajustes(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

select public.dash_receita('{}'::jsonb) -> 'ok' as receita_ok,
       public.dash_ajustes('{}'::jsonb) -> 'ok' as ajustes_ok;
