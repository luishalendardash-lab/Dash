-- =====================================================================
-- 91 — REATIVAÇÃO DE LEADS
--
-- Manda leads de lançamentos anteriores para uma automação nova do
-- SellFlux. É a base que já está paga: quem levantou a mão antes e não
-- comprou continua sendo o público mais barato de alcançar.
--
-- O envio acontece em lotes porque a base pode ter milhares de pessoas
-- e o Worker tem limite de tempo por requisição. Cada lote registra
-- quem foi, então parar no meio e retomar não duplica ninguém.
-- =====================================================================

set search_path = dash, public;

create table if not exists dash.reativacoes (
  id           uuid primary key default gen_random_uuid(),
  campanha     text not null,
  pessoa_id    uuid references dash.pessoas(id) on delete cascade,
  inscricao_id uuid references dash.inscricoes(id) on delete set null,
  canal        text not null default 'email',
  enviado_em   timestamptz not null default now(),
  resultado    text,
  erro         text
);

alter table dash.reativacoes enable row level security;

-- a mesma pessoa não entra duas vezes na mesma campanha
create unique index if not exists ux_reativacao_pessoa
  on dash.reativacoes (campanha, pessoa_id);
create index if not exists ix_reativacao_data
  on dash.reativacoes (enviado_em desc);

-- ---------------------------------------------------------------------
-- 1. QUANTOS SÃO, ANTES DE ENVIAR
--
--    p: {
--      lancamentos: ['fpee-2026-01', ...],   vazio = todos
--      excluir_compradores: true,
--      engenheiro: 'todos' | 'sim' | 'nao',
--      excluir_lancamento_atual: true,
--      campanha: 'reativacao-out-26'
--    }
-- ---------------------------------------------------------------------
create or replace function public.previa_reativacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_slugs text[]; v_eng text; v_campanha text; v_atual uuid;
  v_res jsonb; v_por_lanc jsonb;
begin
  if jsonb_typeof(p->'lancamentos') = 'array'
     and jsonb_array_length(p->'lancamentos') > 0 then
    select array_agg(v) into v_slugs
    from jsonb_array_elements_text(p->'lancamentos') v;
  end if;

  v_eng := coalesce(nullif(p->>'engenheiro',''), 'todos');
  v_campanha := nullif(btrim(coalesce(p->>'campanha','')), '');

  -- o lançamento em andamento: quem já está nele não precisa ser
  -- reativado, e receber duas mensagens seguidas irrita
  select id into v_atual from dash.lancamentos
  where status in ('captacao','aquecimento','evento','carrinho')
  order by criado_em desc limit 1;

  with base as (
    select distinct on (p2.id)
      p2.id as pessoa_id, p2.nome, p2.email, p2.telefone,
      i.id as inscricao_id, i.lancamento_id, l.nome as lancamento,
      coalesce(i.engenheiro, false) as engenheiro,
      i.capturado_em
    from dash.inscricoes i
    join dash.pessoas p2 on p2.id = i.pessoa_id
    join dash.lancamentos l on l.id = i.lancamento_id
    where (v_slugs is null or l.slug = any(v_slugs))
      and p2.email is not null
      -- sem e-mail não há como enviar por e-mail
      and (v_eng = 'todos'
           or (v_eng = 'sim' and coalesce(i.engenheiro, false))
           or (v_eng = 'nao' and not coalesce(i.engenheiro, false)))
    order by p2.id, i.capturado_em desc
  ),
  filtrada as (
    select b.* from base b
    where
      -- quem comprou não recebe oferta de novo
      (not coalesce((p->>'excluir_compradores')::boolean, true)
       or not exists (
         select 1 from dash.vendas v
         where v.pessoa_id = b.pessoa_id and v.status = 'aprovada'))
      -- quem já está no lançamento atual
      and (not coalesce((p->>'excluir_lancamento_atual')::boolean, true)
           or v_atual is null
           or not exists (
             select 1 from dash.inscricoes i2
             where i2.pessoa_id = b.pessoa_id and i2.lancamento_id = v_atual))
      -- quem já recebeu esta campanha
      and (v_campanha is null
           or not exists (
             select 1 from dash.reativacoes r
             where r.campanha = v_campanha and r.pessoa_id = b.pessoa_id))
  )
  select
    jsonb_build_object(
      'total', count(*),
      'com_telefone', count(*) filter (where telefone is not null),
      'engenheiros', count(*) filter (where engenheiro)
    ),
    (select jsonb_agg(jsonb_build_object('lancamento', lancamento, 'leads', n)
              order by n desc)
     from (select lancamento, count(*) as n from filtrada group by lancamento) t)
  into v_res, v_por_lanc
  from filtrada;

  return jsonb_build_object(
    'ok', true,
    'resumo', v_res,
    'por_lancamento', coalesce(v_por_lanc, '[]'::jsonb),
    'campanha', v_campanha,
    -- números de contexto, para a escolha não ser às cegas
    'descartados', jsonb_build_object(
      'compradores', (
        select count(distinct i.pessoa_id) from dash.inscricoes i
        join dash.lancamentos l on l.id = i.lancamento_id
        where (v_slugs is null or l.slug = any(v_slugs))
          and exists (select 1 from dash.vendas v
                      where v.pessoa_id = i.pessoa_id and v.status = 'aprovada')),
      'sem_email', (
        select count(distinct i.pessoa_id) from dash.inscricoes i
        join dash.pessoas p3 on p3.id = i.pessoa_id
        join dash.lancamentos l on l.id = i.lancamento_id
        where (v_slugs is null or l.slug = any(v_slugs)) and p3.email is null),
      'ja_no_lancamento_atual', (
        select count(distinct i.pessoa_id) from dash.inscricoes i
        join dash.lancamentos l on l.id = i.lancamento_id
        where (v_slugs is null or l.slug = any(v_slugs))
          and v_atual is not null
          and exists (select 1 from dash.inscricoes i2
                      where i2.pessoa_id = i.pessoa_id and i2.lancamento_id = v_atual))
    )
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. O PRÓXIMO LOTE
--    Devolve os dados prontos para o Worker enviar.
-- ---------------------------------------------------------------------
create or replace function public.lote_reativacao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_slugs text[]; v_eng text; v_campanha text; v_atual uuid;
  v_limite int; v_res jsonb;
begin
  v_campanha := nullif(btrim(coalesce(p->>'campanha','')), '');
  if v_campanha is null then
    return jsonb_build_object('ok', false, 'erro', 'de um nome a campanha');
  end if;

  if jsonb_typeof(p->'lancamentos') = 'array'
     and jsonb_array_length(p->'lancamentos') > 0 then
    select array_agg(v) into v_slugs
    from jsonb_array_elements_text(p->'lancamentos') v;
  end if;

  v_eng := coalesce(nullif(p->>'engenheiro',''), 'todos');
  v_limite := least(coalesce(nullif(p->>'limite','')::int, 200), 500);

  select id into v_atual from dash.lancamentos
  where status in ('captacao','aquecimento','evento','carrinho')
  order by criado_em desc limit 1;

  with base as (
    select distinct on (p2.id)
      p2.id as pessoa_id, p2.nome, p2.email, p2.telefone,
      i.id as inscricao_id, l.nome as lancamento,
      coalesce(i.engenheiro, false) as engenheiro,
      i.capturado_em
    from dash.inscricoes i
    join dash.pessoas p2 on p2.id = i.pessoa_id
    join dash.lancamentos l on l.id = i.lancamento_id
    where (v_slugs is null or l.slug = any(v_slugs))
      and p2.email is not null
      and (v_eng = 'todos'
           or (v_eng = 'sim' and coalesce(i.engenheiro, false))
           or (v_eng = 'nao' and not coalesce(i.engenheiro, false)))
    order by p2.id, i.capturado_em desc
  )
  select jsonb_agg(jsonb_build_object(
    'pessoa_id', pessoa_id, 'inscricao_id', inscricao_id,
    'nome', nome, 'email', email, 'telefone', telefone,
    'lancamento', lancamento, 'engenheiro', engenheiro
  ))
  into v_res
  from (
    select b.* from base b
    where (not coalesce((p->>'excluir_compradores')::boolean, true)
           or not exists (select 1 from dash.vendas v
                          where v.pessoa_id = b.pessoa_id and v.status = 'aprovada'))
      and (not coalesce((p->>'excluir_lancamento_atual')::boolean, true)
           or v_atual is null
           or not exists (select 1 from dash.inscricoes i2
                          where i2.pessoa_id = b.pessoa_id and i2.lancamento_id = v_atual))
      and not exists (select 1 from dash.reativacoes r
                      where r.campanha = v_campanha and r.pessoa_id = b.pessoa_id)
    order by b.capturado_em desc
    limit v_limite
  ) t;

  return jsonb_build_object('ok', true, 'campanha', v_campanha,
                            'leads', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 3. REGISTRAR O QUE FOI ENVIADO
-- ---------------------------------------------------------------------
create or replace function public.registrar_reativacao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_item jsonb; v_qtd int := 0;
begin
  for v_item in select * from jsonb_array_elements(coalesce(p->'envios','[]'::jsonb))
  loop
    insert into dash.reativacoes
      (campanha, pessoa_id, inscricao_id, canal, resultado, erro)
    values (
      p->>'campanha',
      nullif(v_item->>'pessoa_id','')::uuid,
      nullif(v_item->>'inscricao_id','')::uuid,
      coalesce(nullif(v_item->>'canal',''), 'email'),
      coalesce(nullif(v_item->>'resultado',''), 'enviado'),
      nullif(v_item->>'erro','')
    )
    on conflict (campanha, pessoa_id) do nothing;
    v_qtd := v_qtd + 1;
  end loop;

  return jsonb_build_object('ok', true, 'registrados', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 4. HISTÓRICO
--    Quantos foram, e quantos voltaram a comprar depois.
-- ---------------------------------------------------------------------
create or replace function public.historico_reativacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'campanha', campanha, 'enviados', n, 'falhas', falhas,
    'primeiro', primeiro, 'ultimo', ultimo,
    'compraram_depois', compraram, 'receita', receita
  ) order by ultimo desc)
  into v_res
  from (
    select
      r.campanha,
      count(*) as n,
      count(*) filter (where r.erro is not null) as falhas,
      min(r.enviado_em)::date as primeiro,
      max(r.enviado_em)::date as ultimo,
      -- o número que diz se valeu: quem comprou depois de receber
      count(*) filter (where exists (
        select 1 from dash.vendas v
        where v.pessoa_id = r.pessoa_id
          and v.status = 'aprovada'
          and v.ocorreu_em > r.enviado_em)) as compraram,
      coalesce(round(sum((
        select coalesce(sum(v.valor_bruto), 0) from dash.vendas v
        where v.pessoa_id = r.pessoa_id
          and v.status = 'aprovada'
          and v.ocorreu_em > r.enviado_em)), 2), 0) as receita
    from dash.reativacoes r
    group by r.campanha
  ) t;

  return jsonb_build_object('ok', true, 'campanhas', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. LANÇAMENTOS DISPONÍVEIS PARA ESCOLHER
-- ---------------------------------------------------------------------
create or replace function public.lancamentos_com_leads(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'slug', slug, 'nome', nome, 'leads', leads,
    'engenheiros', engenheiros, 'compradores', compradores,
    'quando', inicio
  ) order by inicio desc)
  into v_res
  from (
    select l.slug, l.nome,
           coalesce(l.captacao_inicio, l.criado_em)::date as inicio,
           count(i.id) as leads,
           count(*) filter (where coalesce(i.engenheiro, false)) as engenheiros,
           count(*) filter (where exists (
             select 1 from dash.vendas v
             where v.pessoa_id = i.pessoa_id and v.status = 'aprovada')) as compradores
    from dash.lancamentos l
    join dash.inscricoes i on i.lancamento_id = l.id
    group by l.slug, l.nome, l.captacao_inicio, l.criado_em
  ) t;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.previa_reativacao(jsonb), public.lote_reativacao(jsonb),
  public.registrar_reativacao(jsonb), public.historico_reativacao(jsonb),
  public.lancamentos_com_leads(jsonb) from public, anon, authenticated;
grant execute on function public.previa_reativacao(jsonb), public.lote_reativacao(jsonb),
  public.registrar_reativacao(jsonb), public.historico_reativacao(jsonb),
  public.lancamentos_com_leads(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
