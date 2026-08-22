-- =====================================================================
-- 51 — ESCOLHER AS CAMPANHAS DO LANÇAMENTO
--
-- A sincronização normal filtra campanhas pelo código no nome. Nos
-- lançamentos antigos esse código não existe, e renomear campanha
-- encerrada altera o histórico do Meta.
--
-- Aqui o caminho é outro: buscamos tudo que gastou no período do
-- lançamento e você marca o que pertence a ele. Mais preciso do que o
-- nome, porque no mesmo período costuma rodar remarketing e outros
-- funis que não são daquele lançamento.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. CAMPANHAS CANDIDATAS
--    Guarda o que a API devolveu, para a tela mostrar antes de decidir.
-- ---------------------------------------------------------------------
create table if not exists dash.ads_candidatas (
  id            text primary key,
  lancamento_id uuid references dash.lancamentos(id) on delete cascade,
  nome          text,
  conta_id      text,
  gasto         numeric(14,2) default 0,
  impressoes    bigint default 0,
  primeiro_dia  date,
  ultimo_dia    date,
  escolhida     boolean not null default false,
  visto_em      timestamptz not null default now()
);

alter table dash.ads_candidatas enable row level security;
create index if not exists ix_cand_lanc on dash.ads_candidatas (lancamento_id);

-- ---------------------------------------------------------------------
-- 2. GUARDAR O QUE A API TROUXE
-- ---------------------------------------------------------------------
create or replace function public.ingest_candidatas(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_item jsonb; v_qtd int := 0; v_total numeric := 0;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  -- a lista é substituída a cada busca: gasto de campanha muda
  delete from dash.ads_candidatas where lancamento_id = v_lanc;

  for v_item in select * from jsonb_array_elements(coalesce(p->'campanhas','[]'::jsonb))
  loop
    insert into dash.ads_candidatas
      (id, lancamento_id, nome, conta_id, gasto, impressoes, primeiro_dia, ultimo_dia)
    values (
      v_item->>'id', v_lanc,
      coalesce(nullif(v_item->>'nome',''), v_item->>'id'),
      v_item->>'conta',
      coalesce(dash.valor_para_numero(v_item->>'gasto'), 0),
      coalesce(nullif(v_item->>'impressoes','')::bigint, 0),
      nullif(v_item->>'de','')::date,
      nullif(v_item->>'ate','')::date
    )
    on conflict (id) do update set
      lancamento_id = excluded.lancamento_id,
      gasto = excluded.gasto,
      nome = excluded.nome,
      visto_em = now();

    v_qtd := v_qtd + 1;
    v_total := v_total + coalesce(dash.valor_para_numero(v_item->>'gasto'), 0);
  end loop;

  -- pré-marca o que parece ser do lançamento: nome com o código, ou com
  -- a palavra captação. É só um palpite; a decisão continua sua.
  update dash.ads_candidatas c set escolhida = true
  from dash.lancamentos l
  where c.lancamento_id = l.id and l.id = v_lanc
    and (
      (l.codigo is not null and upper(c.nome) like upper(l.codigo) || '%')
      or upper(translate(c.nome, 'ÇÃÁÉÍÓÚÂÊÔ', 'CAAEIOUAEO')) like '%CAPTACAO%'
    );

  return jsonb_build_object('ok', true, 'campanhas', v_qtd,
                            'gasto_total', round(v_total, 2),
                            'pre_marcadas', (select count(*) from dash.ads_candidatas
                                             where lancamento_id = v_lanc and escolhida));
end $$;

-- ---------------------------------------------------------------------
-- 3. LISTAR PARA A TELA
-- ---------------------------------------------------------------------
create or replace function public.candidatas_do_lancamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb; v_de timestamptz; v_ate timestamptz;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select min(capturado_em), max(capturado_em) into v_de, v_ate
  from dash.inscricoes where lancamento_id = v_lanc;

  select jsonb_agg(jsonb_build_object(
    'id', id, 'nome', nome, 'conta', conta_id,
    'gasto', gasto, 'impressoes', impressoes,
    'de', primeiro_dia, 'ate', ultimo_dia, 'escolhida', escolhida
  ) order by gasto desc)
  into v_res
  from dash.ads_candidatas where lancamento_id = v_lanc;

  return jsonb_build_object(
    'ok', true,
    'campanhas', coalesce(v_res, '[]'::jsonb),
    'periodo_leads', jsonb_build_object('de', v_de, 'ate', v_ate),
    'escolhido', (select coalesce(round(sum(gasto),2),0) from dash.ads_candidatas
                  where lancamento_id = v_lanc and escolhida),
    'ja_importado', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights
                     where lancamento_id = v_lanc)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. MARCAR E DESMARCAR
-- ---------------------------------------------------------------------
create or replace function public.escolher_campanhas(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_ids text[];
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select array_agg(v) into v_ids
  from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) v;

  update dash.ads_candidatas
  set escolhida = (v_ids is not null and id = any(v_ids))
  where lancamento_id = v_lanc;

  return jsonb_build_object('ok', true,
    'escolhidas', (select count(*) from dash.ads_candidatas
                   where lancamento_id = v_lanc and escolhida),
    'gasto', (select coalesce(round(sum(gasto),2),0) from dash.ads_candidatas
              where lancamento_id = v_lanc and escolhida));
end $$;

-- ---------------------------------------------------------------------
-- 5. IDS ESCOLHIDOS, PARA O WORKER BUSCAR OS ANÚNCIOS
-- ---------------------------------------------------------------------
create or replace function public.campanhas_escolhidas(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_ids jsonb; v_de date; v_ate date;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  select jsonb_agg(id) into v_ids
  from dash.ads_candidatas where lancamento_id = v_lanc and escolhida;

  -- a janela vem dos leads, com folga para o gasto anterior ao primeiro
  select
    percentile_disc(0.02) within group (order by capturado_em)::date - 3,
    percentile_disc(0.98) within group (order by capturado_em)::date + 3
  into v_de, v_ate
  from dash.inscricoes
  where lancamento_id = v_lanc and capturado_em < now() - interval '1 day';

  if v_ate - v_de > 90 then v_ate := v_de + 90; end if;

  return jsonb_build_object('ok', true,
    'ids', coalesce(v_ids, '[]'::jsonb), 'de', v_de, 'ate', v_ate,
    'contas', (select coalesce(config->'meta_contas','[]'::jsonb)
               from dash.lancamentos where id = v_lanc));
end $$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.ingest_candidatas(jsonb), public.candidatas_do_lancamento(jsonb),
  public.escolher_campanhas(jsonb), public.campanhas_escolhidas(jsonb)
  from public, anon, authenticated;
grant execute on function public.ingest_candidatas(jsonb), public.candidatas_do_lancamento(jsonb),
  public.escolher_campanhas(jsonb), public.campanhas_escolhidas(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

select 'pronto' as status;
