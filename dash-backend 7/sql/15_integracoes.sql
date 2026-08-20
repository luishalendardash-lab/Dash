-- =====================================================================
-- 15 — INTEGRAÇÕES
--
-- Uma tela onde o cliente ativa a integração, copia o webhook e cola na
-- plataforma dele. O status vem do que realmente chegou: se a última
-- entrega foi há 8 dias no meio de um lançamento, algo quebrou.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. TABELA
-- ---------------------------------------------------------------------
create table if not exists dash.integracoes (
  slug          text primary key,
  nome          text not null,
  categoria     text not null,          -- venda | crm | whatsapp | ads | video
  emoji         text not null default '🔗',
  cor           text not null default '#666666',
  ativa         boolean not null default false,
  direcao       text not null default 'entrada',  -- entrada | saida | ambas
  fonte_webhook text,                   -- o :fonte da URL /w/:fonte/:secret
  config        jsonb not null default '{}',
  segredos      jsonb not null default '{}',      -- nunca sai por inteiro na API
  instrucoes    text,
  ordem         int not null default 0,
  atualizado_em timestamptz not null default now()
);

alter table dash.integracoes enable row level security;

-- ---------------------------------------------------------------------
-- 2. CATÁLOGO
-- ---------------------------------------------------------------------
insert into dash.integracoes
  (slug, nome, categoria, emoji, cor, direcao, fonte_webhook, ordem, instrucoes) values

  ('hotmart', 'Hotmart', 'venda', '🔥', '#EF4B25', 'entrada', 'hotmart', 1,
   'Ferramentas > Webhook (Notificações) > Cadastrar. Cole a URL abaixo, escolha a versão 2.0 e marque os eventos de compra aprovada, cancelada, reembolso e chargeback. Depois copie o Hottok que a Hotmart mostra e cole aqui — ele é o que garante que o webhook veio mesmo dela.'),

  ('kiwify', 'Kiwify', 'venda', '🥝', '#0A9D5C', 'entrada', 'hotmart', 2,
   'Apps > Webhooks > Criar webhook. Cole a URL e marque compra aprovada, recusada, reembolso e chargeback.'),

  ('guru', 'Digital Manager Guru', 'venda', '🎯', '#5B4BE8', 'entrada', 'hotmart', 3,
   'Configurações > Webhooks > Novo. Cole a URL e selecione os eventos de transação.'),

  ('sellflux', 'SellFlux', 'crm', '📧', '#2563EB', 'ambas', 'sellflux', 4,
   'Entrada: cadastre a URL abaixo no webhook do SellFlux para espelhar tags e etapas na dash. Saída: cole aqui a URL de POST do formulário do SellFlux para a dash mandar os leads capturados e disparar a sequência de e-mail.'),

  ('sendflow', 'SendFlow', 'whatsapp', '💬', '#25D366', 'entrada', 'sendflow', 5,
   'Cole a URL abaixo no webhook de entrada e saída de grupo. Assim a dash sabe quem realmente entrou no grupo, e não apenas quem clicou no link.'),

  ('manychat', 'ManyChat', 'whatsapp', '🤖', '#0084FF', 'ambas', 'manychat', 6,
   'Saída: cole aqui o webhook que recebe o lead e o envia ao ManyChat. Entrada: use a URL abaixo em uma ação de External Request para registrar mensagem enviada e resposta do lead.'),

  ('meta-ads', 'Meta Ads', 'ads', '📣', '#0866FF', 'saida', null, 7,
   'A dash busca campanhas e gastos direto na API do Meta. Precisa de um token de usuário do sistema com ads_read, cadastrado como secret no Worker, e do código do lançamento no início do nome das campanhas.'),

  ('youtube', 'YouTube', 'video', '🎥', '#FF0000', 'saida', null, 8,
   'Para audiência e retenção das aulas. Ainda não implementado.')

on conflict (slug) do update set
  nome = excluded.nome, categoria = excluded.categoria, emoji = excluded.emoji,
  cor = excluded.cor, direcao = excluded.direcao,
  fonte_webhook = excluded.fonte_webhook, ordem = excluded.ordem,
  instrucoes = excluded.instrucoes;

-- ---------------------------------------------------------------------
-- 3. LISTAR — com sinal de vida vindo dos webhooks recebidos
-- ---------------------------------------------------------------------
create or replace function public.dash_integracoes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'slug', i.slug,
    'nome', i.nome,
    'categoria', i.categoria,
    'emoji', i.emoji,
    'cor', i.cor,
    'ativa', i.ativa,
    'direcao', i.direcao,
    'fonte_webhook', i.fonte_webhook,
    'instrucoes', i.instrucoes,
    'config', i.config,
    -- só o final de cada segredo, o suficiente para conferir sem expor
    'segredos_definidos', (
      select coalesce(jsonb_object_agg(k, '••••' || right(v::text, 5)), '{}'::jsonb)
      from jsonb_each_text(i.segredos) as s(k, v)
      where v <> ''
    ),
    'ultimo_evento', a.ultimo,
    'eventos_7d', coalesce(a.qtd, 0),
    'falhas_7d', coalesce(a.falhas, 0)
  ) order by i.ordem)
  into v_res
  from dash.integracoes i
  left join lateral (
    select max(recebido_em) as ultimo,
           count(*) filter (where recebido_em > now() - interval '7 days') as qtd,
           count(*) filter (where recebido_em > now() - interval '7 days'
                              and processado = false) as falhas
    from dash.webhooks_raw w
    where w.fonte = i.fonte_webhook
  ) a on true;

  return jsonb_build_object('ok', true, 'integracoes', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 4. SALVAR
--    p: { slug, ativa, config:{...}, segredos:{...} }
--    Segredo vazio não apaga o que já existe — a tela nunca devolve o
--    valor inteiro, então mandar vazio significa "não mexi nisso".
-- ---------------------------------------------------------------------
create or replace function public.salvar_integracao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_slug text; v_novos jsonb;
begin
  v_slug := nullif(p->>'slug','');
  if v_slug is null then
    return jsonb_build_object('ok', false, 'erro', 'informe a integracao');
  end if;
  if not exists (select 1 from dash.integracoes where slug = v_slug) then
    return jsonb_build_object('ok', false, 'erro', 'integracao desconhecida');
  end if;

  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_novos
  from jsonb_each_text(coalesce(p->'segredos','{}'::jsonb)) as s(k, v)
  where btrim(v) <> '';

  update dash.integracoes set
    ativa = coalesce((p->>'ativa')::boolean, ativa),
    config = case when p ? 'config' then coalesce(p->'config','{}'::jsonb) else config end,
    segredos = segredos || coalesce(v_novos, '{}'::jsonb),
    atualizado_em = now()
  where slug = v_slug;

  return jsonb_build_object('ok', true, 'slug', v_slug);
end $$;

-- ---------------------------------------------------------------------
-- 5. LER SEGREDO — usado pelo Worker, nunca pelo navegador
-- ---------------------------------------------------------------------
create or replace function public.integracao_segredo(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v jsonb;
begin
  select jsonb_build_object(
    'ativa', ativa,
    'valor', segredos->>(p->>'chave'),
    'config', config
  ) into v
  from dash.integracoes where slug = p->>'slug';
  return coalesce(v, jsonb_build_object('ativa', false));
end $$;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.dash_integracoes(jsonb), public.salvar_integracao(jsonb),
  public.integracao_segredo(jsonb) from public, anon, authenticated;
grant execute on function public.dash_integracoes(jsonb), public.salvar_integracao(jsonb),
  public.integracao_segredo(jsonb) to service_role;

grant all privileges on all tables in schema dash to service_role;

-- ---------------------------------------------------------------------
-- 7. CONFERE
-- ---------------------------------------------------------------------
select public.dash_integracoes('{}'::jsonb);
