-- =====================================================================
-- 23 — PRODUTOS
--
-- Quebra de receita por produto e filtro de múltipla seleção, na Home e
-- na tela de Vendas.
--
-- O nome do produto vem da plataforma como texto livre — e cada uma
-- escreve do seu jeito. Por isso o agrupamento normaliza espaço e caixa:
-- "Perito da Elétrica " e "PERITO DA ELETRICA" precisam ser a mesma
-- linha, senão o faturamento aparece dividido em dois.
-- =====================================================================

set search_path = dash, public;

create index if not exists ix_vendas_produto on dash.vendas (lancamento_id, produto);

-- ---------------------------------------------------------------------
-- 1. NORMALIZAÇÃO DO NOME
-- ---------------------------------------------------------------------
create or replace function dash.chave_produto(nome text)
returns text language sql immutable as $$
  -- caixa, espaço duplicado e acento. Sem tirar acento, "Perito da
  -- Elétrica" e "PERITO DA ELETRICA" viram duas linhas e o faturamento
  -- do mesmo produto aparece dividido.
  select nullif(
    upper(btrim(regexp_replace(
      translate(
        coalesce(nome,''),
        'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
        'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN'
      ),
      '\s+', ' ', 'g'))),
  '');
$$;

-- ---------------------------------------------------------------------
-- 2. LISTA DE PRODUTOS — alimenta o filtro
-- ---------------------------------------------------------------------
create or replace function public.dash_produtos(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  -- agrupa e só depois monta o json: a lista de plataformas sai do
  -- próprio agrupamento, sem subconsulta correlacionada
  with agrupado as (
    select
      coalesce(dash.chave_produto(v.produto), '(sem produto)') as chave,
      min(v.produto) as nome,
      count(*) as vendas,
      round(sum(v.valor_bruto), 2) as receita,
      jsonb_agg(distinct v.plataforma) as plataformas
    from dash.vendas v
    where v.status = 'aprovada'
      and (v_lanc is null or v.lancamento_id = v_lanc)
    group by coalesce(dash.chave_produto(v.produto), '(sem produto)')
  )
  select jsonb_agg(jsonb_build_object(
    'chave', chave,
    'nome', coalesce(nome, '(sem produto)'),
    'plataformas', plataformas,
    'vendas', vendas,
    'receita', receita
  ) order by receita desc)
  into v_res
  from agrupado;

  return jsonb_build_object('ok', true, 'produtos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 3. RECEITA COM FILTRO E QUEBRA POR PRODUTO
--    p.produtos = ["PERITO DA ELETRICA", "MENTORIA"]  (chaves)
--    Vazio ou ausente = todos.
-- ---------------------------------------------------------------------
create or replace function public.dash_receita(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_inicio timestamptz; v_fim timestamptz; v_imposto numeric;
  v_filtro text[];
  v_linhas jsonb; v_produtos jsonb;
  v_bruto numeric := 0; v_liquido numeric := 0; v_itens int := 0; v_pago numeric := 0;
begin
  v_inicio := coalesce((p->>'inicio')::timestamptz, date_trunc('month', now()));
  v_fim    := coalesce((p->>'fim')::timestamptz, now() + interval '1 day');

  select coalesce((valor)::text::numeric, 0) into v_imposto
  from dash.config where chave = 'imposto_percentual';
  v_imposto := coalesce(v_imposto, 0);

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
      ) as liquido_plataforma,
      sum(case when vf.plataforma = 'tmb'
               then coalesce(vf.valor_recebido, 0) else vf.valor_bruto end) as pago
    from vendas_filtradas vf
    left join dash.plataformas pl on pl.slug = vf.plataforma
    group by vf.plataforma
  ),
  porproduto as (
    select
      vf.pchave,
      min(vf.produto) as nome,
      count(*) as itens,
      sum(vf.valor_bruto) as bruto,
      count(distinct vf.plataforma) as plataformas
    from vendas_filtradas vf
    group by vf.pchave
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
        'liquido', round(b.liquido_plataforma * (1 - v_imposto/100), 2),
        'pago', round(b.pago, 2),
        'parcelado', b.plataforma = 'tmb'
      ) order by b.bruto desc)
      from base b left join dash.plataformas pl on pl.slug = b.plataforma
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'chave', pp.pchave,
        'nome', coalesce(pp.nome, '(sem produto)'),
        'vendas', pp.itens,
        'receita', round(pp.bruto, 2),
        'ticket', round(pp.bruto / nullif(pp.itens,0), 2),
        'plataformas', pp.plataformas
      ) order by pp.bruto desc)
      from porproduto pp
    ), '[]'::jsonb),
    coalesce((select sum(bruto) from base), 0),
    coalesce((select sum(liquido_plataforma * (1 - v_imposto/100)) from base), 0),
    coalesce((select sum(itens) from base), 0),
    coalesce((select sum(pago) from base), 0)
  into v_linhas, v_produtos, v_bruto, v_liquido, v_itens, v_pago;

  return jsonb_build_object(
    'ok', true,
    'inicio', v_inicio, 'fim', v_fim,
    'imposto_percentual', v_imposto,
    'plataformas', v_linhas,
    'produtos', v_produtos,
    'filtrado', v_filtro is not null,
    'total_bruto', round(v_bruto, 2),
    'total_liquido', round(v_liquido, 2),
    'total_itens', v_itens,
    'total_pago', round(v_pago, 2)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. VENDAS COM FILTRO E QUEBRA POR PRODUTO
--
-- O filtro é aplicado numa view temporária por consulta (CTE). Cada
-- bloco repete a condição — mais verboso, mas evita tabela temporária
-- dentro de função, que depende do controle de transação e falha de
-- formas difíceis de diagnosticar.
-- ---------------------------------------------------------------------
create or replace function public.dash_vendas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_imposto numeric; v_filtro text[];
  v_resumo jsonb; v_origem jsonb; v_lista jsonb;
  v_dia jsonb; v_sck jsonb; v_prod jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

  select coalesce((valor)::text::numeric, 0) into v_imposto
  from dash.config where chave = 'imposto_percentual';
  v_imposto := coalesce(v_imposto, 0);

  select array_agg(value) into v_filtro
  from jsonb_array_elements_text(coalesce(p->'produtos','[]'::jsonb));
  if v_filtro is not null and array_length(v_filtro, 1) is null then v_filtro := null; end if;

  -- ---- resumo
  select jsonb_build_object(
    'aprovadas',   count(*) filter (where status = 'aprovada'),
    'pendentes',   count(*) filter (where status = 'pendente'),
    'reembolsos',  count(*) filter (where status in ('reembolsada','chargeback')),
    'bruto',       round(coalesce(sum(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'liquido',     round(coalesce(sum(
                     case when valor_liquido > 0 then valor_liquido else valor_bruto * 0.9 end
                   ) filter (where status = 'aprovada'), 0) * (1 - v_imposto/100), 2),
    'ticket',      round(coalesce(avg(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'com_lead',    count(*) filter (where status = 'aprovada' and inscricao_id is not null),
    'sem_lead',    count(*) filter (where status = 'aprovada' and inscricao_id is null),
    'valor_reembolsado', round(coalesce(sum(valor_bruto)
                     filter (where status in ('reembolsada','chargeback')), 0), 2)
  ) into v_resumo
  from dash.vendas v
  where v.lancamento_id = v_lanc
    and (v_filtro is null
         or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro));

  -- ---- por produto
  select jsonb_agg(x order by (x->>'receita')::numeric desc) into v_prod
  from (
    select jsonb_build_object(
      'chave', coalesce(dash.chave_produto(v.produto), '(sem produto)'),
      'nome', coalesce(min(v.produto), '(sem produto)'),
      'vendas', count(*),
      'receita', round(sum(v.valor_bruto), 2),
      'ticket', round(avg(v.valor_bruto), 2),
      'com_lead', count(*) filter (where v.inscricao_id is not null)
    ) as x
    from dash.vendas v
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
      and (v_filtro is null
           or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro))
    group by coalesce(dash.chave_produto(v.produto), '(sem produto)')
  ) t;

  -- ---- por anúncio
  select jsonb_agg(x order by (x->>'receita')::numeric desc) into v_origem
  from (
    select jsonb_build_object(
      'anuncio', coalesce(a.nome, i.utm_content, i.meta_ad_id, '(sem anuncio)'),
      'campanha', coalesce(ac.nome, i.utm_campaign, '(sem campanha)'),
      'vendas', count(*),
      'engenheiros', count(*) filter (where i.engenheiro),
      'receita', round(sum(v.valor_bruto), 2)
    ) as x
    from dash.vendas v
    join dash.inscricoes i on i.id = v.inscricao_id
    left join dash.ads_entidades a on a.id = i.meta_ad_id
    left join dash.ads_entidades aj on aj.id = a.parent_id
    left join dash.ads_entidades ac on ac.id = aj.parent_id
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
      and (v_filtro is null
           or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro))
    group by coalesce(a.nome, i.utm_content, i.meta_ad_id, '(sem anuncio)'),
             coalesce(ac.nome, i.utm_campaign, '(sem campanha)')
  ) t;

  -- ---- por SCK
  select jsonb_agg(x order by (x->>'receita')::numeric desc) into v_sck
  from (
    select jsonb_build_object(
      'sck', coalesce(nullif(btrim(v.src_hotmart), ''), '(sem sck)'),
      'vendas', count(*),
      'receita', round(sum(v.valor_bruto), 2),
      'ticket', round(avg(v.valor_bruto), 2),
      'com_lead', count(*) filter (where v.inscricao_id is not null)
    ) as x
    from dash.vendas v
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
      and (v_filtro is null
           or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro))
    group by coalesce(nullif(btrim(v.src_hotmart), ''), '(sem sck)')
  ) t;

  -- ---- dia a dia
  -- o acumulado sai numa etapa própria: função de janela não pode ficar
  -- dentro de jsonb_agg
  with diario as (
    select v.ocorreu_em::date as dia, count(*) qtd, round(sum(v.valor_bruto),2) receita
    from dash.vendas v
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
      and (v_filtro is null
           or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro))
    group by 1
  ),
  com_acumulado as (
    select dia, qtd, receita,
           sum(receita) over (order by dia) as acumulado,
           sum(qtd) over (order by dia) as vendas_acumuladas
    from diario
  )
  select jsonb_agg(jsonb_build_object(
    'dia', dia, 'vendas', qtd, 'receita', receita,
    'acumulado', acumulado, 'vendas_acumuladas', vendas_acumuladas
  ) order by dia)
  into v_dia
  from com_acumulado;

  -- ---- lista
  select jsonb_agg(x order by (x->>'ocorreu_em') desc) into v_lista
  from (
    select jsonb_build_object(
      'id', v.id,
      'nome', coalesce(p2.nome, v.email_comprador, '—'),
      'email', coalesce(p2.email, v.email_comprador),
      'produto', v.produto, 'oferta', v.oferta,
      'status', v.status, 'metodo', v.metodo,
      'valor', v.valor_bruto, 'parcelas', v.parcelas,
      'valor_parcela', nullif(v.raw->>'valor_parcela','')::numeric,
      'sck', nullif(btrim(v.src_hotmart), ''),
      'plataforma', v.plataforma,
      'ocorreu_em', v.ocorreu_em,
      'inscricao_id', v.inscricao_id,
      'campanha', i.utm_campaign,
      'anuncio', coalesce(a.nome, i.utm_content, i.meta_ad_id),
      'engenheiro', coalesce(i.engenheiro, false),
      'atribuida', v.inscricao_id is not null
    ) as x
    from dash.vendas v
    left join dash.inscricoes i on i.id = v.inscricao_id
    left join dash.pessoas p2 on p2.id = v.pessoa_id
    left join dash.ads_entidades a on a.id = i.meta_ad_id
    where v.lancamento_id = v_lanc
      and (v_filtro is null
           or coalesce(dash.chave_produto(v.produto), '(sem produto)') = any(v_filtro))
    order by v.ocorreu_em desc
    limit 200
  ) t;

  return jsonb_build_object(
    'ok', true,
    'resumo', coalesce(v_resumo, '{}'::jsonb),
    'produtos', coalesce(v_prod, '[]'::jsonb),
    'origem', coalesce(v_origem, '[]'::jsonb),
    'por_sck', coalesce(v_sck, '[]'::jsonb),
    'dia_a_dia', coalesce(v_dia, '[]'::jsonb),
    'vendas', coalesce(v_lista, '[]'::jsonb),
    'filtrado', v_filtro is not null
  );
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.dash_produtos(jsonb) from public, anon, authenticated;
grant execute on function public.dash_produtos(jsonb), public.dash_receita(jsonb),
  public.dash_vendas(jsonb) to service_role;

select public.dash_produtos('{}'::jsonb);
