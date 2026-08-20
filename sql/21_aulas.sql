-- =====================================================================
-- 21 — AULAS (diário de bordo)
--
-- Números lançados à mão. Sem API, sem coleta automática.
--
-- O valor não está no número solto: está em comparar a aula 1 deste
-- lançamento com a aula 1 do anterior. Por isso a comparação é a peça
-- central desta tela, não um extra.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. COLUNAS
-- ---------------------------------------------------------------------
alter table dash.aulas
  add column if not exists data_aula date,
  add column if not exists link      text;

alter table dash.aula_metricas
  add column if not exists likes           int,
  add column if not exists comentarios     int,
  add column if not exists presentes_inicio int,
  add column if not exists presentes_fim   int,
  add column if not exists retencao_media  numeric(5,2),
  add column if not exists tempo_medio_min numeric(6,2),
  add column if not exists observacoes     text;

-- ---------------------------------------------------------------------
-- 2. SALVAR AULA E SEUS NÚMEROS — tudo numa chamada
-- ---------------------------------------------------------------------
create or replace function public.salvar_aula(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_id uuid;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  if p ? 'id' and nullif(p->>'id','') is not null then
    v_id := (p->>'id')::uuid;
    update dash.aulas set
      numero = coalesce(nullif(p->>'numero','')::int, numero),
      titulo = coalesce(nullif(p->>'titulo',''), titulo),
      data_aula = coalesce(nullif(p->>'data_aula','')::date, data_aula),
      link = coalesce(nullif(p->>'link',''), link),
      duracao_seg = coalesce(nullif(p->>'duracao_min','')::int * 60, duracao_seg),
      observacoes = coalesce(p->>'diario', observacoes)
    where id = v_id;
  else
    insert into dash.aulas
      (lancamento_id, numero, titulo, data_aula, link, duracao_seg, observacoes)
    values (
      v_lanc,
      coalesce(nullif(p->>'numero','')::int,
               (select coalesce(max(numero),0)+1 from dash.aulas where lancamento_id = v_lanc)),
      coalesce(nullif(p->>'titulo',''), 'Aula'),
      nullif(p->>'data_aula','')::date,
      nullif(p->>'link',''),
      nullif(p->>'duracao_min','')::int * 60,
      p->>'diario'
    )
    on conflict (lancamento_id, numero) do update set
      titulo = excluded.titulo,
      data_aula = excluded.data_aula,
      link = excluded.link,
      duracao_seg = excluded.duracao_seg
    returning id into v_id;
  end if;

  -- números da aula
  insert into dash.aula_metricas (aula_id) values (v_id)
  on conflict (aula_id) do nothing;

  update dash.aula_metricas set
    views = coalesce(nullif(p->>'views','')::bigint, views),
    pico_simultaneos = coalesce(nullif(p->>'pico','')::int, pico_simultaneos),
    presentes_inicio = coalesce(nullif(p->>'presentes_inicio','')::int, presentes_inicio),
    presentes_fim = coalesce(nullif(p->>'presentes_fim','')::int, presentes_fim),
    retencao_media = coalesce(nullif(p->>'retencao_media','')::numeric, retencao_media),
    tempo_medio_min = coalesce(nullif(p->>'tempo_medio_min','')::numeric, tempo_medio_min),
    likes = coalesce(nullif(p->>'likes','')::int, likes),
    comentarios = coalesce(nullif(p->>'comentarios','')::int, comentarios),
    atualizado_em = now()
  where aula_id = v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.apagar_aula(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
begin
  delete from dash.aulas where id = (p->>'id')::uuid;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 3. TELA — aulas deste lançamento com o comparativo do anterior
--
--    A comparação é por NÚMERO da aula: aula 1 com aula 1, aula 2 com
--    aula 2. Comparar por data não faria sentido, já que cada lançamento
--    tem seu calendário.
-- ---------------------------------------------------------------------
create or replace function public.dash_aulas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_slug text; v_criado timestamptz;
  v_ant uuid; v_ant_nome text; v_res jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id, slug, criado_em into v_lanc, v_slug, v_criado
    from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id, slug, criado_em into v_lanc, v_slug, v_criado
    from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

  -- lançamento anterior: o mais recente antes deste que tenha aula com número
  select l.id, l.nome into v_ant, v_ant_nome
  from dash.lancamentos l
  where l.criado_em < v_criado
    and exists (select 1 from dash.aulas a where a.lancamento_id = l.id)
  order by l.criado_em desc limit 1;

  select jsonb_agg(x order by (x->>'numero')::int) into v_res
  from (
    select jsonb_build_object(
      'id', a.id,
      'numero', a.numero,
      'titulo', a.titulo,
      'data_aula', a.data_aula,
      'link', a.link,
      'duracao_min', a.duracao_seg / 60,
      'diario', a.observacoes,
      'views', m.views,
      'pico', m.pico_simultaneos,
      'presentes_inicio', m.presentes_inicio,
      'presentes_fim', m.presentes_fim,
      'retencao_media', m.retencao_media,
      'tempo_medio_min', m.tempo_medio_min,
      'likes', m.likes,
      'comentarios', m.comentarios,
      -- quanto da audiência ficou até o fim
      'segurou', case when coalesce(m.pico_simultaneos,0) > 0 and m.presentes_fim is not null
                      then round(100.0 * m.presentes_fim / m.pico_simultaneos, 1) end,
      -- mesma aula no lançamento anterior
      'anterior', case when v_ant is null then null else (
        select jsonb_build_object(
          'views', ma.views,
          'pico', ma.pico_simultaneos,
          'presentes_fim', ma.presentes_fim,
          'retencao_media', ma.retencao_media,
          'segurou', case when coalesce(ma.pico_simultaneos,0) > 0 and ma.presentes_fim is not null
                          then round(100.0 * ma.presentes_fim / ma.pico_simultaneos, 1) end
        )
        from dash.aulas aa
        left join dash.aula_metricas ma on ma.aula_id = aa.id
        where aa.lancamento_id = v_ant and aa.numero = a.numero
        limit 1
      ) end
    ) as x
    from dash.aulas a
    left join dash.aula_metricas m on m.aula_id = a.id
    where a.lancamento_id = v_lanc
  ) t;

  return jsonb_build_object(
    'ok', true,
    'lancamento', v_slug,
    'comparando_com', v_ant_nome,
    'aulas', coalesce(v_res, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. HISTÓRICO — a mesma aula em todos os lançamentos
-- ---------------------------------------------------------------------
create or replace function public.dash_aulas_historico(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(x order by (x->>'criado_em') desc) into v_res
  from (
    select jsonb_build_object(
      'lancamento', l.nome,
      'codigo', l.codigo,
      'criado_em', l.criado_em,
      'aulas', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'numero', a.numero,
          'titulo', a.titulo,
          'views', m.views,
          'pico', m.pico_simultaneos,
          'presentes_fim', m.presentes_fim,
          'retencao_media', m.retencao_media
        ) order by a.numero), '[]'::jsonb)
        from dash.aulas a
        left join dash.aula_metricas m on m.aula_id = a.id
        where a.lancamento_id = l.id
      )
    ) as x
    from dash.lancamentos l
    where exists (select 1 from dash.aulas a where a.lancamento_id = l.id)
  ) t;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.salvar_aula(jsonb), public.apagar_aula(jsonb),
  public.dash_aulas(jsonb), public.dash_aulas_historico(jsonb)
  from public, anon, authenticated;
grant execute on function public.salvar_aula(jsonb), public.apagar_aula(jsonb),
  public.dash_aulas(jsonb), public.dash_aulas_historico(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

-- ---------------------------------------------------------------------
-- 6. INTEGRAÇÃO DO YOUTUBE: por ora, manual
-- ---------------------------------------------------------------------
update dash.integracoes set
  ativa = false,
  instrucoes = 'Os números das aulas são lançados à mão na aba Aulas, direto do YouTube Studio. Nenhuma integração é necessária. O pico de simultâneos você anota durante a live; views, retenção e tempo médio saem do Studio depois.',
  passos = '[
    "Durante a live, anote o maior número de pessoas assistindo ao mesmo tempo.",
    "Depois da aula, abra o YouTube Studio > Análises da transmissão.",
    "Copie views, retenção média e tempo médio de exibição.",
    "Lance tudo na aba Aulas da dash. A comparação com o lançamento anterior aparece sozinha."
  ]'::jsonb,
  campos = '[]'::jsonb
where slug = 'youtube';

select public.dash_aulas('{}'::jsonb);
