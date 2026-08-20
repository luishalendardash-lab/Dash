-- =====================================================================
-- 05 — ETAPA DO LEAD (calculada, não mantida à mão)
--
-- A etapa é derivada dos eventos que já existem. Ninguém marca, ninguém
-- desmarca, nunca desatualiza. Tag manual fica como exceção, para o que
-- realmente precisa de curadoria humana.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. COLUNAS
-- ---------------------------------------------------------------------
alter table dash.inscricoes
  add column if not exists etapa text not null default 'frio',
  add column if not exists tags_manuais text[] not null default '{}',
  add column if not exists sellflux_stage_id text,
  add column if not exists sellflux_tags text[];

create index if not exists ix_inscricoes_etapa on dash.inscricoes (lancamento_id, etapa);
create index if not exists ix_inscricoes_tags  on dash.inscricoes using gin (tags_manuais);

-- ---------------------------------------------------------------------
-- 2. A REGRA — ordem importa: a etapa mais avançada vence
-- ---------------------------------------------------------------------
create or replace function dash.calcular_etapa(p_inscricao uuid)
returns text language plpgsql stable as $$
declare r record;
begin
  select i.comprou, i.aulas_assistidas, i.entrou_grupo, i.fez_quiz,
         i.whats_confirmado, i.lead_tier
  into r
  from dash.inscricoes i where i.id = p_inscricao;

  if r is null then return 'frio'; end if;

  if r.comprou then return 'comprou'; end if;
  if r.aulas_assistidas > 0 then return 'engajado'; end if;
  if r.entrou_grupo then return 'aquecido'; end if;
  if r.fez_quiz then return 'qualificado'; end if;
  if r.whats_confirmado then return 'contatado'; end if;
  return 'frio';
end $$;

-- ---------------------------------------------------------------------
-- 3. RECALCULA A CADA EVENTO (estende o trigger que já existia)
-- ---------------------------------------------------------------------
create or replace function dash.tg_evento_atualiza_inscricao()
returns trigger language plpgsql as $$
begin
  if new.inscricao_id is null then return new; end if;

  if new.tipo = 'quiz_respondido' then
    update dash.inscricoes set fez_quiz = true,
      quiz_em = coalesce(quiz_em, new.ocorreu_em), atualizado_em = now()
    where id = new.inscricao_id;

  elsif new.tipo = 'grupo_entrou' then
    update dash.inscricoes set entrou_grupo = true,
      grupo_em = coalesce(grupo_em, new.ocorreu_em),
      grupo_nome = coalesce(grupo_nome, new.payload->>'grupo'), atualizado_em = now()
    where id = new.inscricao_id;

  elsif new.tipo = 'grupo_saiu' then
    update dash.inscricoes set entrou_grupo = false, atualizado_em = now()
    where id = new.inscricao_id;

  elsif new.tipo = 'whats_respondido' then
    update dash.inscricoes set whats_confirmado = true, atualizado_em = now()
    where id = new.inscricao_id;

  elsif new.tipo = 'aula_assistiu' then
    update dash.inscricoes set aulas_assistidas = aulas_assistidas + 1, atualizado_em = now()
    where id = new.inscricao_id;

  elsif new.tipo = 'compra' then
    update dash.inscricoes set comprou = true,
      comprou_em = coalesce(comprou_em, new.ocorreu_em), atualizado_em = now()
    where id = new.inscricao_id;
  end if;

  -- etapa sempre por último, depois que os flags já mudaram
  update dash.inscricoes
  set etapa = dash.calcular_etapa(new.inscricao_id)
  where id = new.inscricao_id;

  return new;
end $$;

-- ---------------------------------------------------------------------
-- 4. RPC PARA ESPELHAR TAG/ETAPA VINDAS DO SELLFLUX
--    (o SellFlux continua sendo dono das automações dele; a gente só
--     registra o que ele informa, sem deixar isso mandar na nossa etapa)
-- ---------------------------------------------------------------------
create or replace function public.ingest_sellflux_estado(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_pessoa uuid; v_insc uuid; v_lanc uuid; v_tags text[];
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;

  begin
    v_pessoa := dash.upsert_pessoa(p->>'email', p->>'telefone', p->>'nome');
  exception when others then
    return jsonb_build_object('ok', false, 'erro', 'sem identificador');
  end;

  select id into v_insc from dash.inscricoes
  where pessoa_id = v_pessoa and lancamento_id = v_lanc;
  if v_insc is null then
    return jsonb_build_object('ok', false, 'erro', 'inscricao nao encontrada');
  end if;

  select array_agg(value::text) into v_tags
  from jsonb_array_elements_text(coalesce(p->'tags','[]'::jsonb)) as value;

  update dash.inscricoes set
    sellflux_stage_id = coalesce(nullif(p->>'stage_id',''), sellflux_stage_id),
    sellflux_tags = coalesce(v_tags, sellflux_tags),
    atualizado_em = now()
  where id = v_insc;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, fonte, payload)
  values (v_lanc, v_pessoa, v_insc, 'estado_sellflux', 'sellflux',
          jsonb_build_object('stage_id', p->>'stage_id', 'tags', p->'tags'));

  return jsonb_build_object('ok', true, 'inscricao_id', v_insc);
end $$;

revoke all on function public.ingest_sellflux_estado(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_sellflux_estado(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 5. BACKFILL DO QUE JÁ EXISTE
-- ---------------------------------------------------------------------
update dash.inscricoes set etapa = dash.calcular_etapa(id);

-- ---------------------------------------------------------------------
-- 6. FUNIL POR ETAPA — vira a coluna da esquerda da dash
-- ---------------------------------------------------------------------
create or replace view dash.v_funil_etapas as
select
  l.slug as lancamento,
  i.etapa,
  count(*) as leads,
  round(100.0 * count(*) / nullif(sum(count(*)) over (partition by l.slug), 0), 1) as percentual
from dash.inscricoes i
join dash.lancamentos l on l.id = i.lancamento_id
group by l.slug, i.etapa;

-- etapa cruzada com criativo: a pergunta que a dash existe para responder
create or replace view dash.v_etapa_por_anuncio as
select
  l.slug as lancamento,
  coalesce(a.nome, i.meta_ad_id, 'sem atribuicao') as anuncio,
  count(*) filter (where i.etapa = 'frio')        as frio,
  count(*) filter (where i.etapa = 'qualificado') as qualificado,
  count(*) filter (where i.etapa = 'aquecido')    as aquecido,
  count(*) filter (where i.etapa = 'engajado')    as engajado,
  count(*) filter (where i.etapa = 'comprou')     as comprou,
  count(*) as total
from dash.inscricoes i
join dash.lancamentos l on l.id = i.lancamento_id
left join dash.ads_entidades a on a.id = i.meta_ad_id
group by l.slug, coalesce(a.nome, i.meta_ad_id, 'sem atribuicao');

-- ---------------------------------------------------------------------
-- 7. CONFERE
-- ---------------------------------------------------------------------
select * from dash.v_funil_etapas;
