-- =====================================================================
-- 06 — DADOS DA HOME
-- Plataformas de venda, regras de imposto, flag de engenheiro
-- e as 3 RPCs que alimentam os cards da tela principal.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. PLATAFORMAS DE VENDA
--    A taxa aqui é só fallback: quando a plataforma informa o valor
--    líquido no webhook, o informado sempre vence.
-- ---------------------------------------------------------------------
create table if not exists dash.plataformas (
  slug            text primary key,
  nome            text not null,
  inicial         text not null,
  cor             text not null default '#666666',
  taxa_percentual numeric(6,3) not null default 0,   -- ex: 9.9 = 9,9%
  taxa_fixa       numeric(10,2) not null default 0,
  ativa           boolean not null default true,
  ordem           int not null default 0
);

alter table dash.plataformas enable row level security;

insert into dash.plataformas (slug, nome, inicial, cor, taxa_percentual, taxa_fixa, ordem) values
  ('hotmart', 'Hotmart',    'H', '#EF4B25', 9.9, 1.00, 1),
  ('kiwify',  'Kiwify',     'K', '#0A9D5C', 8.9, 2.49, 2),
  ('guru',    'Guru',       'G', '#5B4BE8', 7.9, 1.00, 3),
  ('pix',     'Pix direto', 'P', '#00A3A3', 0.0, 0.00, 4)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- 2. CONFIGURAÇÃO FINANCEIRA (o adm edita nos ajustes)
-- ---------------------------------------------------------------------
create table if not exists dash.config (
  chave      text primary key,
  valor      jsonb not null,
  descricao  text,
  atualizado_em timestamptz not null default now()
);

alter table dash.config enable row level security;

insert into dash.config (chave, valor, descricao) values
  ('imposto_percentual', '6.0'::jsonb, 'Percentual de imposto sobre a receita liquida da plataforma')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- 3. FLAG DE ENGENHEIRO
--    Preenchida pelo quiz. Fica como coluna própria porque é KPI da home
--    e não pode depender de varrer quiz_respostas a cada carregamento.
-- ---------------------------------------------------------------------
alter table dash.inscricoes
  add column if not exists engenheiro boolean not null default false;

create index if not exists ix_inscricoes_engenheiro
  on dash.inscricoes (lancamento_id, engenheiro) where engenheiro;

-- ---------------------------------------------------------------------
-- 4. RPC — RECEITA POR PLATAFORMA
--    p: { inicio: '2026-08-01', fim: '2026-08-31' }  (ambos opcionais)
-- ---------------------------------------------------------------------
create or replace function public.dash_receita(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_inicio timestamptz;
  v_fim    timestamptz;
  v_imposto numeric;
  v_linhas jsonb;
  v_bruto numeric := 0;
  v_liquido numeric := 0;
  v_itens int := 0;
begin
  v_inicio := coalesce((p->>'inicio')::timestamptz, date_trunc('month', now()));
  v_fim    := coalesce((p->>'fim')::timestamptz, now() + interval '1 day');

  select coalesce((valor)::text::numeric, 0) into v_imposto
  from dash.config where chave = 'imposto_percentual';
  v_imposto := coalesce(v_imposto, 0);

  with base as (
    select
      v.plataforma,
      count(*) as itens,
      sum(v.valor_bruto) as bruto,
      -- líquido informado pela plataforma vence; senão aplica a taxa cadastrada
      sum(
        case when v.valor_liquido > 0 then v.valor_liquido
             else greatest(0, v.valor_bruto
                  - (v.valor_bruto * coalesce(pl.taxa_percentual,0) / 100)
                  - coalesce(pl.taxa_fixa,0))
        end
      ) as liquido_plataforma
    from dash.vendas v
    left join dash.plataformas pl on pl.slug = v.plataforma
    where v.status = 'aprovada'
      and v.ocorreu_em >= v_inicio and v.ocorreu_em < v_fim
    group by v.plataforma
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'slug', b.plataforma,
      'nome', coalesce(pl.nome, initcap(b.plataforma)),
      'inicial', coalesce(pl.inicial, upper(left(b.plataforma,1))),
      'cor', coalesce(pl.cor, '#666666'),
      'itens', b.itens,
      'bruto', round(b.bruto, 2),
      'liquido', round(b.liquido_plataforma * (1 - v_imposto/100), 2)
    ) order by b.bruto desc), '[]'::jsonb),
    coalesce(sum(b.bruto), 0),
    coalesce(sum(b.liquido_plataforma * (1 - v_imposto/100)), 0),
    coalesce(sum(b.itens), 0)
  into v_linhas, v_bruto, v_liquido, v_itens
  from base b
  left join dash.plataformas pl on pl.slug = b.plataforma;

  return jsonb_build_object(
    'ok', true,
    'inicio', v_inicio, 'fim', v_fim,
    'imposto_percentual', v_imposto,
    'plataformas', v_linhas,
    'total_bruto', round(v_bruto, 2),
    'total_liquido', round(v_liquido, 2),
    'total_itens', v_itens
  );
end $$;

-- ---------------------------------------------------------------------
-- 5. RPC — MÉTRICAS DE CAPTURA
--    p: { lancamento: 'lanc-2026-09' }
-- ---------------------------------------------------------------------
create or replace function public.dash_captura(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc dash.lancamentos%rowtype;
  v_leads int; v_eng int; v_investido numeric;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select * into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc.id is null then
    select * into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc.id is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento');
  end if;

  select count(*), count(*) filter (where engenheiro)
  into v_leads, v_eng
  from dash.inscricoes where lancamento_id = v_lanc.id;

  select coalesce(sum(gasto), 0) into v_investido
  from dash.ads_insights where lancamento_id = v_lanc.id;

  return jsonb_build_object(
    'ok', true,
    'lancamento', v_lanc.slug,
    'nome', v_lanc.nome,
    'status', v_lanc.status,
    'leads', v_leads,
    'engenheiros', v_eng,
    'investido', round(v_investido, 2),
    'cpl', case when v_leads > 0 then round(v_investido / v_leads, 2) end,
    'cpl_engenheiro', case when v_eng > 0 then round(v_investido / v_eng, 2) end,
    'meta_leads', v_lanc.meta_leads,
    'leads_faltantes', case when v_lanc.meta_leads is not null
                            then greatest(0, v_lanc.meta_leads - v_leads) end,
    'orcamento', v_lanc.investimento_planejado,
    'verba_restante', case when v_lanc.investimento_planejado is not null
                           then greatest(0, v_lanc.investimento_planejado - v_investido) end
  );
end $$;

-- ---------------------------------------------------------------------
-- 6. RPC — SÉRIE DIÁRIA DA CAPTAÇÃO
--    p: { lancamento: '...', dias: 30 }
--    Dias sem captura aparecem zerados — senão o gráfico mente.
-- ---------------------------------------------------------------------
create or replace function public.dash_serie_diaria(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_slug text; v_dias int; v_inicio date; v_res jsonb;
begin
  v_dias := least(90, greatest(7, coalesce((p->>'dias')::int, 30)));

  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, slug into v_lanc, v_slug from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id, slug into v_lanc, v_slug from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

  v_inicio := (now() - (v_dias || ' days')::interval)::date;

  with dias as (
    select generate_series(v_inicio, now()::date, '1 day')::date as dia
  ),
  leads as (
    select capturado_em::date as dia,
           count(*) as leads,
           count(*) filter (where engenheiro) as engenheiros
    from dash.inscricoes
    where lancamento_id = v_lanc and capturado_em::date >= v_inicio
    group by 1
  ),
  gasto as (
    select data_ref as dia, sum(gasto) as investido
    from dash.ads_insights
    where lancamento_id = v_lanc and data_ref >= v_inicio
    group by 1
  )
  select jsonb_agg(jsonb_build_object(
    'dia', d.dia,
    'leads', coalesce(l.leads, 0),
    'engenheiros', coalesce(l.engenheiros, 0),
    'investido', round(coalesce(g.investido, 0), 2),
    'cpl', case when coalesce(l.leads,0) > 0
                then round(coalesce(g.investido,0) / l.leads, 2) else 0 end
  ) order by d.dia)
  into v_res
  from dias d
  left join leads l on l.dia = d.dia
  left join gasto g on g.dia = d.dia;

  return jsonb_build_object('ok', true, 'lancamento', v_slug, 'dados', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 7. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.dash_receita(jsonb), public.dash_captura(jsonb),
  public.dash_serie_diaria(jsonb) from public, anon, authenticated;

grant execute on function public.dash_receita(jsonb), public.dash_captura(jsonb),
  public.dash_serie_diaria(jsonb) to service_role;

grant usage on schema dash to service_role;
grant all privileges on all tables in schema dash to service_role;

-- ---------------------------------------------------------------------
-- 8. METAS DO LANÇAMENTO ATIVO (ajuste os números do cliente)
-- ---------------------------------------------------------------------
update dash.lancamentos
set meta_leads = 12000, investimento_planejado = 110000
where slug = 'lanc-2026-09';

-- ---------------------------------------------------------------------
-- 9. CONFERE
-- ---------------------------------------------------------------------
select public.dash_captura('{}'::jsonb);
select public.dash_receita('{}'::jsonb);
select public.dash_serie_diaria('{"dias":14}'::jsonb);
