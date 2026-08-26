-- =====================================================================
-- 64 — PAGAMENTOS PENDENTES E RECUPERAÇÃO
--
-- PIX e boleto gerados que ainda não foram pagos. É dinheiro na mesa
-- durante o carrinho, e o único jeito de saber quem realmente não pagou
-- é cruzar e-mail + produto contra as vendas aprovadas: muita gente gera
-- boleto e paga no PIX depois, ou gera duas vezes.
--
-- O disparo de recuperação fica registrado, para a mesma pessoa não
-- receber a mesma cobrança duas vezes no mesmo dia.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. QUE STATUS SIGNIFICA "AINDA NÃO PAGOU"
--    Cada plataforma escreve de um jeito.
-- ---------------------------------------------------------------------
create or replace function dash.status_pendente(p_status text)
returns boolean language sql immutable as $$
  select lower(coalesce(p_status, '')) in (
    'pendente', 'pending', 'aguardando', 'aguardando_pagamento',
    'waiting_payment', 'billet_printed', 'printed_billet',
    'boleto_impresso', 'started', 'iniciado', 'processing',
    'em_processamento', 'pix_gerado', 'waiting'
  );
$$;

-- ---------------------------------------------------------------------
-- 2. REGISTRO DE DISPAROS
--    Sem isto, cada clique manda de novo para quem já recebeu.
-- ---------------------------------------------------------------------
create table if not exists dash.recuperacoes (
  id            uuid primary key default gen_random_uuid(),
  venda_id      uuid references dash.vendas(id) on delete cascade,
  pessoa_id     uuid references dash.pessoas(id) on delete cascade,
  canal         text not null,
  enviado_em    timestamptz not null default now(),
  resultado     text,
  erro          text
);

alter table dash.recuperacoes enable row level security;
create index if not exists ix_recup_venda on dash.recuperacoes (venda_id, canal);
create index if not exists ix_recup_data on dash.recuperacoes (enviado_em desc);

-- ---------------------------------------------------------------------
-- 3. QUEM ESTÁ DEVENDO
--    p: { lancamento, dias, canal }
-- ---------------------------------------------------------------------
create or replace function public.pagamentos_pendentes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_de timestamptz; v_ate timestamptz;
  v_res jsonb; v_resumo jsonb; v_produtos text[];
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento');
  end if;

  select de, ate into v_de, v_ate from dash.janela_lancamento(v_lanc);

  select array_agg(dash.chave_produto(v)) into v_produtos
  from dash.lancamentos l, jsonb_array_elements_text(
    case when jsonb_typeof(l.config->'produtos') = 'array'
         then l.config->'produtos' else '[]'::jsonb end) v
  where l.id = v_lanc;

  with pendentes as (
    select
      v.id, v.pessoa_id, v.inscricao_id,
      coalesce(v.email_comprador, p.email) as email,
      coalesce(p.nome, '') as nome,
      coalesce(v.fone_comprador, p.telefone) as telefone,
      coalesce(v.produto, '(sem produto)') as produto,
      v.valor_bruto, v.metodo, v.plataforma, v.ocorreu_em, v.status,
      coalesce(i.engenheiro, false) as engenheiro
    from dash.vendas v
    left join dash.pessoas p on p.id = v.pessoa_id
    left join dash.inscricoes i on i.id = v.inscricao_id
    where dash.status_pendente(v.status)
      and v.ocorreu_em between v_de and v_ate
      and (v_produtos is null or dash.chave_produto(v.produto) = any(v_produtos))
  ),
  -- quem já pagou: mesmo e-mail e mesmo produto, com venda aprovada.
  -- Sem esse cruzamento a lista fica cheia de quem gerou boleto e pagou
  -- por PIX no dia seguinte.
  pagos as (
    select distinct
      dash.norm_email(coalesce(v.email_comprador, p2.email)) as email,
      dash.chave_produto(v.produto) as produto
    from dash.vendas v
    left join dash.pessoas p2 on p2.id = v.pessoa_id
    where v.status = 'aprovada'
  ),
  abertos as (
    select pe.*
    from pendentes pe
    where not exists (
      select 1 from pagos pg
      where pg.email = dash.norm_email(pe.email)
        and pg.produto = dash.chave_produto(pe.produto)
    )
  )
  select
    jsonb_agg(jsonb_build_object(
      'venda_id', id,
      'pessoa_id', pessoa_id,
      'nome', nullif(nome, ''),
      'email', email,
      'telefone', telefone,
      'produto', produto,
      'valor', valor_bruto,
      'metodo', metodo,
      'plataforma', plataforma,
      'quando', ocorreu_em,
      'dias', greatest(0, extract(day from now() - ocorreu_em)::int),
      'engenheiro', engenheiro,
      'ja_enviado', (
        select jsonb_agg(distinct r.canal)
        from dash.recuperacoes r
        where r.venda_id = abertos.id
          and r.enviado_em > now() - interval '24 hours'
      )
    ) order by ocorreu_em desc),
    jsonb_build_object(
      'quantidade', count(*),
      'valor_total', round(coalesce(sum(valor_bruto), 0), 2),
      'com_email', count(*) filter (where email is not null),
      'com_telefone', count(*) filter (where telefone is not null),
      'engenheiros', count(*) filter (where engenheiro),
      'pix', count(*) filter (where lower(coalesce(metodo,'')) like '%pix%'),
      'boleto', count(*) filter (where lower(coalesce(metodo,'')) like '%bole%')
    )
  into v_res, v_resumo
  from abertos;

  return jsonb_build_object(
    'ok', true,
    'periodo', jsonb_build_object('de', v_de, 'ate', v_ate),
    'resumo', v_resumo,
    'pendentes', coalesce(v_res, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. QUEM VAI RECEBER
--    Devolve os dados prontos para o Worker disparar, já sem quem
--    recebeu nas últimas 24 horas.
--    p: { lancamento, canal, ids: [...] }
-- ---------------------------------------------------------------------
create or replace function public.alvos_recuperacao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_canal text; v_ids uuid[]; v_res jsonb;
begin
  v_canal := coalesce(nullif(p->>'canal',''), 'email');

  if jsonb_typeof(p->'ids') = 'array' and jsonb_array_length(p->'ids') > 0 then
    select array_agg(v::uuid) into v_ids from jsonb_array_elements_text(p->'ids') v;
  end if;

  with lista as (
    select
      (x->>'venda_id')::uuid as venda_id,
      (x->>'pessoa_id')::uuid as pessoa_id,
      x->>'nome' as nome,
      x->>'email' as email,
      x->>'telefone' as telefone,
      x->>'produto' as produto,
      (x->>'valor')::numeric as valor
    from jsonb_array_elements(
      public.pagamentos_pendentes(jsonb_build_object('lancamento', p->>'lancamento'))
      -> 'pendentes'
    ) x
  )
  select jsonb_agg(jsonb_build_object(
    'venda_id', venda_id, 'pessoa_id', pessoa_id,
    'nome', nome, 'email', email, 'telefone', telefone,
    'produto', produto, 'valor', valor
  ))
  into v_res
  from lista l
  where (v_ids is null or l.venda_id = any(v_ids))
    and (v_canal <> 'email' or l.email is not null)
    and (v_canal <> 'whatsapp' or l.telefone is not null)
    -- não repete para quem já recebeu por este canal hoje
    and not exists (
      select 1 from dash.recuperacoes r
      where r.venda_id = l.venda_id and r.canal = v_canal
        and r.enviado_em > now() - interval '24 hours'
    );

  return jsonb_build_object('ok', true, 'canal', v_canal,
                            'alvos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. REGISTRAR O QUE FOI ENVIADO
-- ---------------------------------------------------------------------
create or replace function public.registrar_recuperacao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_item jsonb; v_qtd int := 0;
begin
  for v_item in select * from jsonb_array_elements(coalesce(p->'envios','[]'::jsonb))
  loop
    insert into dash.recuperacoes (venda_id, pessoa_id, canal, resultado, erro)
    values (
      nullif(v_item->>'venda_id','')::uuid,
      nullif(v_item->>'pessoa_id','')::uuid,
      coalesce(nullif(v_item->>'canal',''), 'email'),
      coalesce(nullif(v_item->>'resultado',''), 'enviado'),
      nullif(v_item->>'erro','')
    );
    v_qtd := v_qtd + 1;
  end loop;

  return jsonb_build_object('ok', true, 'registrados', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 6. HISTÓRICO DE DISPAROS
-- ---------------------------------------------------------------------
create or replace function public.historico_recuperacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'quando', dia, 'canal', canal, 'enviados', n,
    'falhas', falhas, 'recuperados', recuperados
  ) order by dia desc)
  into v_res
  from (
    select
      r.enviado_em::date as dia, r.canal,
      count(*) as n,
      count(*) filter (where r.erro is not null) as falhas,
      -- quantos pagaram depois de receber: o número que diz se vale
      count(*) filter (where exists (
        select 1 from dash.vendas v2
        join dash.vendas v1 on v1.id = r.venda_id
        where v2.status = 'aprovada'
          and v2.ocorreu_em > r.enviado_em
          and dash.norm_email(v2.email_comprador) = dash.norm_email(v1.email_comprador)
      )) as recuperados
    from dash.recuperacoes r
    group by r.enviado_em::date, r.canal
    order by 1 desc
    limit 20
  ) t;

  return jsonb_build_object('ok', true, 'historico', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 7. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.pagamentos_pendentes(jsonb), public.alvos_recuperacao(jsonb),
  public.registrar_recuperacao(jsonb), public.historico_recuperacao(jsonb)
  from public, anon, authenticated;
grant execute on function public.pagamentos_pendentes(jsonb), public.alvos_recuperacao(jsonb),
  public.registrar_recuperacao(jsonb), public.historico_recuperacao(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

select 'pronto' as status;
