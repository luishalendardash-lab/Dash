-- =====================================================================
-- DASH DE LANÇAMENTO — SCHEMA BASE (FASE 1)
-- Postgres / Supabase
-- Rodar inteiro no SQL Editor do Supabase. Idempotente (drop + create).
-- =====================================================================

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";

drop schema if exists dash cascade;
create schema dash;
set search_path = dash, public;

-- =====================================================================
-- 0. FUNÇÕES DE NORMALIZAÇÃO (identidade do lead depende disso)
-- =====================================================================

-- e-mail: minúsculo, sem espaço, remove +alias do gmail
create or replace function dash.norm_email(raw text)
returns text language plpgsql immutable as $$
declare e text; local_part text; domain_part text;
begin
  if raw is null then return null; end if;
  e := lower(btrim(raw));
  if e = '' or position('@' in e) = 0 then return null; end if;
  local_part := split_part(e, '@', 1);
  domain_part := split_part(e, '@', 2);
  if domain_part in ('gmail.com','googlemail.com') then
    local_part := replace(split_part(local_part, '+', 1), '.', '');
    domain_part := 'gmail.com';
  else
    local_part := split_part(local_part, '+', 1);
  end if;
  return local_part || '@' || domain_part;
end $$;

-- telefone BR -> E.164 (+55DDD9XXXXXXXX). Tolera lixo de formulário.
create or replace function dash.norm_phone(raw text)
returns text language plpgsql immutable as $$
declare d text; ddd text; num text;
begin
  if raw is null then return null; end if;
  d := regexp_replace(raw, '\D', '', 'g');
  if d = '' then return null; end if;
  -- tira zeros de operadora / prefixo internacional
  d := regexp_replace(d, '^0+', '');
  if left(d, 2) = '55' and length(d) >= 12 then d := substr(d, 3); end if;
  if length(d) < 10 or length(d) > 11 then return null; end if;
  ddd := left(d, 2);
  num := substr(d, 3);
  -- celular BR: 9 dígitos. fixo: 8. só adiciona o 9 se for faixa de celular.
  if length(num) = 8 and left(num, 1) in ('6','7','8','9') then
    num := '9' || num;
  end if;
  return '+55' || ddd || num;
end $$;

-- =====================================================================
-- 1. LANÇAMENTOS (cada um é uma "aba" da dash)
-- =====================================================================

create table dash.lancamentos (
  id              uuid primary key default gen_random_uuid(),
  slug            text not null unique,          -- ex: 'lanc-2026-09'
  nome            text not null,
  produto         text,
  status          text not null default 'planejado'
                  check (status in ('planejado','captacao','aquecimento','evento','carrinho','encerrado')),
  captacao_inicio timestamptz,
  captacao_fim    timestamptz,
  carrinho_abre   timestamptz,
  carrinho_fecha  timestamptz,
  meta_leads      int,
  meta_faturamento numeric(14,2),
  investimento_planejado numeric(14,2),
  config          jsonb not null default '{}',   -- ids de conta de ads, canal yt, produto hotmart etc.
  criado_em       timestamptz not null default now()
);

create index on dash.lancamentos (status);

-- =====================================================================
-- 2. PESSOAS (identidade única, atravessa lançamentos)
-- =====================================================================

create table dash.pessoas (
  id           uuid primary key default gen_random_uuid(),
  email        text unique,                       -- já normalizado
  telefone     text unique,                       -- já normalizado E.164
  nome         text,
  primeiro_contato timestamptz not null default now(),
  ultimo_contato   timestamptz not null default now(),
  atributos    jsonb not null default '{}',
  criado_em    timestamptz not null default now(),
  constraint pessoa_precisa_de_chave check (email is not null or telefone is not null)
);

create index on dash.pessoas using gin (nome gin_trgm_ops);

-- aliases: e-mails/telefones secundários que caem no mesmo humano
create table dash.pessoa_identificadores (
  id         uuid primary key default gen_random_uuid(),
  pessoa_id  uuid not null references dash.pessoas(id) on delete cascade,
  tipo       text not null check (tipo in ('email','telefone','manychat_id','sellflux_id','hotmart_id')),
  valor      text not null,
  criado_em  timestamptz not null default now(),
  unique (tipo, valor)
);

create index on dash.pessoa_identificadores (pessoa_id);

-- upsert de pessoa por email/telefone. Retorna o id canônico.
create or replace function dash.upsert_pessoa(
  p_email text, p_telefone text, p_nome text default null
) returns uuid language plpgsql as $$
declare e text; t text; pid uuid; pid_email uuid; pid_fone uuid;
begin
  e := dash.norm_email(p_email);
  t := dash.norm_phone(p_telefone);
  if e is null and t is null then
    raise exception 'upsert_pessoa: sem email nem telefone válidos (% / %)', p_email, p_telefone;
  end if;

  select id into pid_email from dash.pessoas where email = e and e is not null;
  select id into pid_fone  from dash.pessoas where telefone = t and t is not null;

  -- caso 1: já existe pelos dois lados e são a mesma pessoa (ou só um lado achou)
  pid := coalesce(pid_email, pid_fone);

  if pid is null then
    insert into dash.pessoas (email, telefone, nome)
    values (e, t, nullif(btrim(coalesce(p_nome,'')), ''))
    returning id into pid;
    return pid;
  end if;

  -- caso 2: e-mail e telefone apontam para pessoas diferentes -> guarda o
  -- conflito como identificador secundário, NÃO faz merge automático.
  if pid_email is not null and pid_fone is not null and pid_email <> pid_fone then
    insert into dash.pessoa_identificadores (pessoa_id, tipo, valor)
    values (pid_email, 'telefone', t)
    on conflict do nothing;
  end if;

  update dash.pessoas set
    email    = coalesce(email, e),
    telefone = coalesce(telefone, t),
    nome     = coalesce(nome, nullif(btrim(coalesce(p_nome,'')), '')),
    ultimo_contato = now()
  where id = pid;

  return pid;
end $$;

-- =====================================================================
-- 3. INSCRIÇÕES (pessoa × lançamento) — o "lead" de um lançamento
-- =====================================================================

create table dash.inscricoes (
  id             uuid primary key default gen_random_uuid(),
  lancamento_id  uuid not null references dash.lancamentos(id) on delete cascade,
  pessoa_id      uuid not null references dash.pessoas(id) on delete cascade,
  capturado_em   timestamptz not null default now(),

  -- atribuição FIRST TOUCH (a que vale pro relatório de captação)
  utm_source     text,
  utm_medium     text,
  utm_campaign   text,
  utm_content    text,
  utm_term       text,
  -- IDs reais do Meta (vindos das macros dinâmicas na URL) — chave de ouro
  meta_campaign_id text,
  meta_adset_id    text,
  meta_ad_id       text,
  fbclid           text,
  landing_url      text,
  referrer         text,

  -- estado da jornada (desnormalizado de propósito, pra dash ser rápida)
  fez_quiz         boolean not null default false,
  quiz_em          timestamptz,
  lead_score       int,
  lead_tier        text,           -- A / B / C
  entrou_grupo     boolean not null default false,
  grupo_em         timestamptz,
  grupo_nome       text,
  whats_confirmado boolean not null default false,
  aulas_assistidas int not null default 0,
  comprou          boolean not null default false,
  comprou_em       timestamptz,

  origem_sistema   text,           -- 'sellflux' | 'form_proprio' | 'import'
  sellflux_lead_id text,
  manychat_id      text,
  extras           jsonb not null default '{}',
  atualizado_em    timestamptz not null default now(),

  unique (lancamento_id, pessoa_id)
);

create index on dash.inscricoes (lancamento_id, capturado_em desc);
create index on dash.inscricoes (lancamento_id, meta_ad_id);
create index on dash.inscricoes (lancamento_id, utm_campaign);
create index on dash.inscricoes (pessoa_id);
create index on dash.inscricoes (lancamento_id, lead_tier);
create index on dash.inscricoes (sellflux_lead_id);

-- =====================================================================
-- 4. EVENTOS (linha do tempo de tudo — é isso que alimenta a tela do lead)
-- =====================================================================

create table dash.eventos (
  id             bigserial primary key,
  lancamento_id  uuid references dash.lancamentos(id) on delete cascade,
  pessoa_id      uuid references dash.pessoas(id) on delete cascade,
  inscricao_id   uuid references dash.inscricoes(id) on delete cascade,
  tipo           text not null,
    -- captura | quiz_iniciado | quiz_respondido | grupo_click | grupo_entrou
    -- | grupo_saiu | whats_enviado | whats_respondido | aula_assistiu
    -- | checkout_iniciado | compra | reembolso | descadastro
  ocorreu_em     timestamptz not null default now(),
  fonte          text not null,        -- sellflux | manychat | sendflow | hotmart | meta | youtube | interno
  payload        jsonb not null default '{}',
  dedupe_key     text unique,          -- id do evento na origem, evita duplicar webhook
  criado_em      timestamptz not null default now()
);

create index on dash.eventos (lancamento_id, tipo, ocorreu_em desc);
create index on dash.eventos (pessoa_id, ocorreu_em desc);
create index on dash.eventos (inscricao_id, ocorreu_em);
create index on dash.eventos using gin (payload);

-- =====================================================================
-- 5. QUIZ
-- =====================================================================

create table dash.quiz_perguntas (
  id            uuid primary key default gen_random_uuid(),
  lancamento_id uuid not null references dash.lancamentos(id) on delete cascade,
  chave         text not null,          -- ex: 'faturamento_atual'
  enunciado     text not null,
  ordem         int not null default 0,
  peso          numeric(6,2) not null default 1,
  opcoes        jsonb not null default '[]',   -- [{valor, label, pontos}]
  unique (lancamento_id, chave)
);

create table dash.quiz_respostas (
  id            uuid primary key default gen_random_uuid(),
  inscricao_id  uuid not null references dash.inscricoes(id) on delete cascade,
  pergunta_chave text not null,
  resposta_valor text,
  resposta_label text,
  pontos         numeric(6,2) not null default 0,
  respondido_em  timestamptz not null default now(),
  unique (inscricao_id, pergunta_chave)
);

create index on dash.quiz_respostas (pergunta_chave, resposta_valor);

-- =====================================================================
-- 6. META ADS
-- =====================================================================

create table dash.ads_entidades (
  id             text primary key,       -- id do Meta (campaign/adset/ad)
  nivel          text not null check (nivel in ('campaign','adset','ad')),
  nome           text not null,
  parent_id      text,
  conta_id       text not null,
  lancamento_id  uuid references dash.lancamentos(id) on delete set null,
  status         text,
  objetivo       text,
  criativo       jsonb not null default '{}',  -- thumb, título, corpo, link, id do criativo
  atualizado_em  timestamptz not null default now()
);

create index on dash.ads_entidades (lancamento_id, nivel);
create index on dash.ads_entidades (parent_id);

create table dash.ads_insights (
  id            bigserial primary key,
  data_ref      date not null,
  ad_id         text not null references dash.ads_entidades(id) on delete cascade,
  lancamento_id uuid references dash.lancamentos(id) on delete set null,
  impressoes    bigint not null default 0,
  alcance       bigint not null default 0,
  cliques       bigint not null default 0,
  cliques_link  bigint not null default 0,
  gasto         numeric(14,2) not null default 0,
  ctr           numeric(8,4),
  cpm           numeric(12,4),
  cpc           numeric(12,4),
  leads_meta    int not null default 0,   -- o que o pixel/Meta reporta
  video_3s      bigint not null default 0,
  video_75      bigint not null default 0,
  raw           jsonb not null default '{}',
  atualizado_em timestamptz not null default now(),
  unique (data_ref, ad_id)
);

create index on dash.ads_insights (lancamento_id, data_ref);

-- =====================================================================
-- 7. AULAS (YouTube)
-- =====================================================================

create table dash.aulas (
  id             uuid primary key default gen_random_uuid(),
  lancamento_id  uuid not null references dash.lancamentos(id) on delete cascade,
  numero         int not null,
  titulo         text not null,
  youtube_video_id text,
  inicio_previsto  timestamptz,
  duracao_seg      int,
  is_live          boolean not null default true,
  observacoes      text,                       -- diário de bordo
  unique (lancamento_id, numero)
);

-- pico/curva de audiência ao vivo (coletado por cron a cada 60s)
create table dash.aula_audiencia (
  id           bigserial primary key,
  aula_id      uuid not null references dash.aulas(id) on delete cascade,
  medido_em    timestamptz not null,
  concorrentes int not null,
  unique (aula_id, medido_em)
);

create index on dash.aula_audiencia (aula_id, medido_em);

-- curva de retenção (YouTube Analytics API, pós-evento)
create table dash.aula_retencao (
  id            bigserial primary key,
  aula_id       uuid not null references dash.aulas(id) on delete cascade,
  ratio_video   numeric(5,4) not null,     -- 0.00 a 1.00 do vídeo
  ratio_audiencia numeric(6,4) not null,   -- % ainda assistindo
  unique (aula_id, ratio_video)
);

-- métricas agregadas do vídeo
create table dash.aula_metricas (
  aula_id            uuid primary key references dash.aulas(id) on delete cascade,
  views              bigint not null default 0,
  pico_simultaneos   int not null default 0,
  tempo_medio_seg    int,
  duracao_media_pct  numeric(5,2),
  chats              int not null default 0,
  atualizado_em      timestamptz not null default now()
);

-- presença individual (só existe se a aula for em página própria com player)
create table dash.aula_presenca (
  id           uuid primary key default gen_random_uuid(),
  aula_id      uuid not null references dash.aulas(id) on delete cascade,
  inscricao_id uuid not null references dash.inscricoes(id) on delete cascade,
  entrou_em    timestamptz,
  saiu_em      timestamptz,
  segundos     int not null default 0,
  unique (aula_id, inscricao_id)
);

-- =====================================================================
-- 8. VENDAS
-- =====================================================================

create table dash.vendas (
  id              uuid primary key default gen_random_uuid(),
  lancamento_id   uuid references dash.lancamentos(id) on delete set null,
  pessoa_id       uuid references dash.pessoas(id) on delete set null,
  inscricao_id    uuid references dash.inscricoes(id) on delete set null,
  plataforma      text not null default 'hotmart',
  transacao_id    text not null,
  produto         text,
  oferta          text,
  status          text not null,   -- aprovada | pendente | cancelada | reembolsada | chargeback
  metodo          text,            -- pix | cartao | boleto
  parcelas        int,
  valor_bruto     numeric(14,2) not null default 0,
  valor_liquido   numeric(14,2) not null default 0,
  moeda           text not null default 'BRL',
  email_comprador text,
  fone_comprador  text,
  src_hotmart     text,            -- parâmetro src do checkout
  ocorreu_em      timestamptz not null,
  raw             jsonb not null default '{}',
  criado_em       timestamptz not null default now(),
  unique (plataforma, transacao_id)
);

create index on dash.vendas (lancamento_id, status, ocorreu_em);
create index on dash.vendas (pessoa_id);

-- =====================================================================
-- 9. LOG BRUTO DE WEBHOOK (nada se perde, dá pra reprocessar)
-- =====================================================================

create table dash.webhooks_raw (
  id           bigserial primary key,
  fonte        text not null,
  recebido_em  timestamptz not null default now(),
  headers      jsonb,
  body         jsonb,
  processado   boolean not null default false,
  erro         text
);

create index on dash.webhooks_raw (fonte, recebido_em desc);
create index on dash.webhooks_raw (processado) where processado = false;

-- =====================================================================
-- 10. TRIGGERS DE CONSISTÊNCIA
-- =====================================================================

-- toda vez que entra um evento, atualiza o estado desnormalizado da inscrição
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

  return new;
end $$;

create trigger trg_evento_atualiza_inscricao
after insert on dash.eventos
for each row execute function dash.tg_evento_atualiza_inscricao();

-- venda chega -> tenta amarrar na inscrição do lançamento por pessoa
create or replace function dash.tg_venda_vincula()
returns trigger language plpgsql as $$
declare pid uuid; iid uuid;
begin
  if new.pessoa_id is null then
    begin
      pid := dash.upsert_pessoa(new.email_comprador, new.fone_comprador, null);
      new.pessoa_id := pid;
    exception when others then
      pid := null;
    end;
  else
    pid := new.pessoa_id;
  end if;

  if pid is not null and new.lancamento_id is not null and new.inscricao_id is null then
    select id into iid from dash.inscricoes
    where pessoa_id = pid and lancamento_id = new.lancamento_id;
    new.inscricao_id := iid;
  end if;

  return new;
end $$;

create trigger trg_venda_vincula
before insert or update on dash.vendas
for each row execute function dash.tg_venda_vincula();

-- =====================================================================
-- 11. VIEWS DE LEITURA (é o que o front consome)
-- =====================================================================

-- funil por anúncio: gasto real do Meta × leads reais do banco × vendas reais
create or replace view dash.v_funil_por_anuncio as
select
  l.id                              as lancamento_id,
  l.slug                            as lancamento,
  a.id                              as ad_id,
  a.nome                            as anuncio,
  ac.nome                           as campanha,
  aj.nome                           as conjunto,
  coalesce(g.gasto, 0)              as gasto,
  coalesce(g.impressoes, 0)         as impressoes,
  coalesce(g.cliques_link, 0)       as cliques_link,
  coalesce(i.leads, 0)              as leads,
  coalesce(i.leads_quiz, 0)         as leads_quiz,
  coalesce(i.leads_grupo, 0)        as leads_grupo,
  coalesce(v.vendas, 0)             as vendas,
  coalesce(v.receita, 0)            as receita,
  case when coalesce(i.leads,0) > 0
       then round(coalesce(g.gasto,0) / i.leads, 2) end as cpl_real,
  case when coalesce(g.gasto,0) > 0
       then round(coalesce(v.receita,0) / g.gasto, 2) end as roas
from dash.lancamentos l
join dash.ads_entidades a  on a.lancamento_id = l.id and a.nivel = 'ad'
left join dash.ads_entidades aj on aj.id = a.parent_id
left join dash.ads_entidades ac on ac.id = aj.parent_id
left join (
  select ad_id, sum(gasto) gasto, sum(impressoes) impressoes, sum(cliques_link) cliques_link
  from dash.ads_insights group by ad_id
) g on g.ad_id = a.id
left join (
  select lancamento_id, meta_ad_id,
         count(*) leads,
         count(*) filter (where fez_quiz) leads_quiz,
         count(*) filter (where entrou_grupo) leads_grupo
  from dash.inscricoes group by lancamento_id, meta_ad_id
) i on i.meta_ad_id = a.id and i.lancamento_id = l.id
left join (
  select ins.lancamento_id, ins.meta_ad_id,
         count(*) vendas, sum(vd.valor_bruto) receita
  from dash.vendas vd
  join dash.inscricoes ins on ins.id = vd.inscricao_id
  where vd.status = 'aprovada'
  group by ins.lancamento_id, ins.meta_ad_id
) v on v.meta_ad_id = a.id and v.lancamento_id = l.id;

-- placar do lançamento
create or replace view dash.v_resumo_lancamento as
select
  l.id, l.slug, l.nome, l.status,
  (select count(*) from dash.inscricoes i where i.lancamento_id = l.id) as leads,
  (select count(*) from dash.inscricoes i where i.lancamento_id = l.id and i.fez_quiz) as quiz,
  (select count(*) from dash.inscricoes i where i.lancamento_id = l.id and i.entrou_grupo) as no_grupo,
  (select coalesce(sum(ins.gasto),0) from dash.ads_insights ins where ins.lancamento_id = l.id) as investido,
  (select count(*) from dash.vendas v where v.lancamento_id = l.id and v.status = 'aprovada') as vendas,
  (select coalesce(sum(v.valor_bruto),0) from dash.vendas v where v.lancamento_id = l.id and v.status = 'aprovada') as receita
from dash.lancamentos l;

-- linha do tempo do lead (tela do lead)
create or replace view dash.v_jornada_lead as
select
  i.id as inscricao_id, i.lancamento_id, p.nome, p.email, p.telefone,
  e.tipo, e.ocorreu_em, e.fonte, e.payload
from dash.inscricoes i
join dash.pessoas p on p.id = i.pessoa_id
left join dash.eventos e on e.inscricao_id = i.id
order by e.ocorreu_em;

-- =====================================================================
-- 12. RLS (fechar tudo; acesso só via service_role nos Workers)
-- =====================================================================

alter table dash.lancamentos   enable row level security;
alter table dash.pessoas       enable row level security;
alter table dash.inscricoes    enable row level security;
alter table dash.eventos       enable row level security;
alter table dash.vendas        enable row level security;
alter table dash.quiz_respostas enable row level security;
alter table dash.ads_entidades enable row level security;
alter table dash.ads_insights  enable row level security;
alter table dash.webhooks_raw  enable row level security;

-- =====================================================================
-- 13. SEED DE TESTE
-- =====================================================================

insert into dash.lancamentos (slug, nome, produto, status, captacao_inicio, carrinho_abre, carrinho_fecha)
values ('lanc-2026-09', 'Lançamento Setembro/26', 'Produto Principal', 'captacao',
        now(), now() + interval '14 days', now() + interval '19 days');

do $$
declare lid uuid; pid uuid; iid uuid;
begin
  select id into lid from dash.lancamentos where slug = 'lanc-2026-09';
  pid := dash.upsert_pessoa('TESTE+lead@Gmail.com', '(53) 99999-1234', 'Lead de Teste');

  insert into dash.inscricoes (lancamento_id, pessoa_id, utm_source, utm_campaign,
    meta_campaign_id, meta_adset_id, meta_ad_id, origem_sistema)
  values (lid, pid, 'fb', 'captacao-set', '1200001', '1200002', '1200003', 'sellflux')
  returning id into iid;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, fonte, payload)
  values
    (lid, pid, iid, 'captura', 'sellflux', '{"form":"captura-set"}'),
    (lid, pid, iid, 'quiz_respondido', 'interno', '{"score": 78}'),
    (lid, pid, iid, 'grupo_entrou', 'sendflow', '{"grupo":"Turma 03"}');
end $$;

-- confere
select * from dash.v_resumo_lancamento;
select tipo, ocorreu_em from dash.v_jornada_lead where email = 'teste@gmail.com';
