-- =====================================================================
-- DASH DE LANÇAMENTO — RPCs DE INGESTÃO (FASE 1.2)
-- Rodar depois do 01_schema_dash_lancamento.sql
--
-- Por que as funções ficam em PUBLIC e não em DASH:
-- o PostgREST só expõe os schemas listados em Settings > API > Exposed
-- schemas. Deixando as funções em public, o schema dash inteiro
-- continua fechado — o Worker só consegue chamar estas 4 portas.
-- =====================================================================

set search_path = public;

-- ---------------------------------------------------------------------
-- 1. INGEST_LEAD — captura. Atômico: pessoa + inscrição + evento.
--    Atribuição FIRST TOUCH: UTM só grava se ainda estiver vazia.
-- ---------------------------------------------------------------------
create or replace function public.ingest_lead(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = dash, public
as $$
declare
  v_lanc_id  uuid;
  v_pessoa   uuid;
  v_insc     uuid;
  v_novo     boolean := false;
  v_quando   timestamptz;
  v_utm      jsonb := coalesce(p->'utm', '{}'::jsonb);
  v_meta     jsonb := coalesce(p->'meta', '{}'::jsonb);
begin
  -- lançamento: por slug; se não vier, pega o que está em captação
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc_id from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc_id is null then
    select id into v_lanc_id from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc_id is null then
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento ativo');
  end if;

  v_quando := coalesce((p->>'capturado_em')::timestamptz, now());

  -- pessoa (normaliza e-mail/telefone dentro)
  begin
    v_pessoa := dash.upsert_pessoa(p->>'email', p->>'telefone', p->>'nome');
  exception when others then
    return jsonb_build_object('ok', false, 'erro', 'sem email/telefone validos');
  end;

  -- inscrição: first touch vence, mas preenche buraco se antes veio vazio
  insert into dash.inscricoes (
    lancamento_id, pessoa_id, capturado_em,
    utm_source, utm_medium, utm_campaign, utm_content, utm_term,
    meta_campaign_id, meta_adset_id, meta_ad_id, fbclid,
    landing_url, referrer, origem_sistema, sellflux_lead_id, manychat_id, extras
  ) values (
    v_lanc_id, v_pessoa, v_quando,
    nullif(v_utm->>'source',''),  nullif(v_utm->>'medium',''),
    nullif(v_utm->>'campaign',''),nullif(v_utm->>'content',''),
    nullif(v_utm->>'term',''),
    nullif(v_meta->>'campaign_id',''), nullif(v_meta->>'adset_id',''),
    nullif(v_meta->>'ad_id',''),  nullif(p->>'fbclid',''),
    nullif(p->>'landing_url',''), nullif(p->>'referrer',''),
    coalesce(nullif(p->>'origem',''), 'desconhecida'),
    nullif(p->>'sellflux_lead_id',''), nullif(p->>'manychat_id',''),
    coalesce(p->'extras', '{}'::jsonb)
  )
  on conflict (lancamento_id, pessoa_id) do update set
    utm_source       = coalesce(dash.inscricoes.utm_source,       excluded.utm_source),
    utm_medium       = coalesce(dash.inscricoes.utm_medium,       excluded.utm_medium),
    utm_campaign     = coalesce(dash.inscricoes.utm_campaign,     excluded.utm_campaign),
    utm_content      = coalesce(dash.inscricoes.utm_content,      excluded.utm_content),
    utm_term         = coalesce(dash.inscricoes.utm_term,         excluded.utm_term),
    meta_campaign_id = coalesce(dash.inscricoes.meta_campaign_id, excluded.meta_campaign_id),
    meta_adset_id    = coalesce(dash.inscricoes.meta_adset_id,    excluded.meta_adset_id),
    meta_ad_id       = coalesce(dash.inscricoes.meta_ad_id,       excluded.meta_ad_id),
    fbclid           = coalesce(dash.inscricoes.fbclid,           excluded.fbclid),
    landing_url      = coalesce(dash.inscricoes.landing_url,      excluded.landing_url),
    sellflux_lead_id = coalesce(dash.inscricoes.sellflux_lead_id, excluded.sellflux_lead_id),
    manychat_id      = coalesce(dash.inscricoes.manychat_id,      excluded.manychat_id),
    extras           = dash.inscricoes.extras || excluded.extras,
    atualizado_em    = now()
  returning id, (xmax = 0) into v_insc, v_novo;

  -- evento de captura (dedupe pela chave da origem)
  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, ocorreu_em, fonte, payload, dedupe_key)
  values (
    v_lanc_id, v_pessoa, v_insc, 'captura', v_quando,
    coalesce(nullif(p->>'origem',''), 'desconhecida'),
    coalesce(p->'payload', '{}'::jsonb),
    nullif(p->>'dedupe_key','')
  )
  on conflict (dedupe_key) do nothing;

  update dash.pessoas set ultimo_contato = greatest(ultimo_contato, v_quando) where id = v_pessoa;

  return jsonb_build_object(
    'ok', true, 'novo', v_novo,
    'pessoa_id', v_pessoa, 'inscricao_id', v_insc, 'lancamento_id', v_lanc_id
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. INGEST_EVENTO — qualquer etapa da jornada, identificando por
--    e-mail OU telefone. Se a pessoa não existe, cria (lead órfão).
-- ---------------------------------------------------------------------
create or replace function public.ingest_evento(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = dash, public
as $$
declare
  v_lanc_id uuid; v_pessoa uuid; v_insc uuid; v_quando timestamptz;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc_id from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc_id is null then
    select id into v_lanc_id from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;

  v_quando := coalesce((p->>'ocorreu_em')::timestamptz, now());

  if p ? 'inscricao_id' and nullif(p->>'inscricao_id','') is not null then
    select id, pessoa_id, lancamento_id into v_insc, v_pessoa, v_lanc_id
    from dash.inscricoes where id = (p->>'inscricao_id')::uuid;
  else
    begin
      v_pessoa := dash.upsert_pessoa(p->>'email', p->>'telefone', p->>'nome');
    exception when others then
      return jsonb_build_object('ok', false, 'erro', 'sem identificador');
    end;
    select id into v_insc from dash.inscricoes
    where pessoa_id = v_pessoa and lancamento_id = v_lanc_id;
  end if;

  if v_pessoa is null then
    return jsonb_build_object('ok', false, 'erro', 'pessoa nao resolvida');
  end if;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, ocorreu_em, fonte, payload, dedupe_key)
  values (
    v_lanc_id, v_pessoa, v_insc,
    coalesce(nullif(p->>'tipo',''), 'desconhecido'),
    v_quando,
    coalesce(nullif(p->>'fonte',''), 'desconhecida'),
    coalesce(p->'payload', '{}'::jsonb),
    nullif(p->>'dedupe_key','')
  )
  on conflict (dedupe_key) do nothing;

  update dash.pessoas set ultimo_contato = greatest(ultimo_contato, v_quando) where id = v_pessoa;

  return jsonb_build_object('ok', true, 'pessoa_id', v_pessoa, 'inscricao_id', v_insc);
end $$;

-- ---------------------------------------------------------------------
-- 3. INGEST_QUIZ — respostas + score em uma chamada
-- ---------------------------------------------------------------------
create or replace function public.ingest_quiz(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = dash, public
as $$
declare
  v_pessoa uuid; v_insc uuid; v_lanc uuid;
  v_r jsonb; v_total numeric := 0; v_tier text;
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

  -- quem respondeu o quiz sem ter passado pela captura: cria a inscrição
  if v_insc is null then
    insert into dash.inscricoes (lancamento_id, pessoa_id, origem_sistema)
    values (v_lanc, v_pessoa, 'quiz') returning id into v_insc;
  end if;

  for v_r in select * from jsonb_array_elements(coalesce(p->'respostas','[]'::jsonb))
  loop
    insert into dash.quiz_respostas (inscricao_id, pergunta_chave, resposta_valor, resposta_label, pontos)
    values (
      v_insc, v_r->>'chave', v_r->>'valor', v_r->>'label',
      coalesce((v_r->>'pontos')::numeric, 0)
    )
    on conflict (inscricao_id, pergunta_chave) do update set
      resposta_valor = excluded.resposta_valor,
      resposta_label = excluded.resposta_label,
      pontos = excluded.pontos,
      respondido_em = now();
    v_total := v_total + coalesce((v_r->>'pontos')::numeric, 0);
  end loop;

  if p ? 'score' then v_total := (p->>'score')::numeric; end if;

  v_tier := coalesce(nullif(p->>'tier',''),
            case when v_total >= 70 then 'A' when v_total >= 40 then 'B' else 'C' end);

  update dash.inscricoes set
    lead_score = round(v_total), lead_tier = v_tier,
    fez_quiz = true, quiz_em = coalesce(quiz_em, now()), atualizado_em = now()
  where id = v_insc;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, fonte, payload, dedupe_key)
  values (v_lanc, v_pessoa, v_insc, 'quiz_respondido',
          coalesce(nullif(p->>'fonte',''),'quiz'),
          jsonb_build_object('score', v_total, 'tier', v_tier, 'respostas', p->'respostas'),
          nullif(p->>'dedupe_key',''))
  on conflict (dedupe_key) do nothing;

  return jsonb_build_object('ok', true, 'inscricao_id', v_insc, 'score', v_total, 'tier', v_tier);
end $$;

-- ---------------------------------------------------------------------
-- 4. INGEST_VENDA — Hotmart. Amarra no lead pelo e-mail/telefone.
-- ---------------------------------------------------------------------
create or replace function public.ingest_venda(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = dash, public
as $$
declare v_lanc uuid; v_venda uuid; v_insc uuid;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('carrinho','evento') order by criado_em desc limit 1;
  end if;

  insert into dash.vendas (
    lancamento_id, plataforma, transacao_id, produto, oferta, status, metodo,
    parcelas, valor_bruto, valor_liquido, moeda,
    email_comprador, fone_comprador, src_hotmart, ocorreu_em, raw
  ) values (
    v_lanc,
    coalesce(nullif(p->>'plataforma',''), 'hotmart'),
    p->>'transacao_id', p->>'produto', p->>'oferta',
    coalesce(nullif(p->>'status',''), 'pendente'), p->>'metodo',
    nullif(p->>'parcelas','')::int,
    coalesce((p->>'valor_bruto')::numeric, 0),
    coalesce((p->>'valor_liquido')::numeric, 0),
    coalesce(nullif(p->>'moeda',''), 'BRL'),
    p->>'email', p->>'telefone', p->>'src',
    coalesce((p->>'ocorreu_em')::timestamptz, now()),
    coalesce(p->'raw','{}'::jsonb)
  )
  on conflict (plataforma, transacao_id) do update set
    status = excluded.status,
    valor_liquido = excluded.valor_liquido,
    raw = excluded.raw
  returning id, inscricao_id into v_venda, v_insc;

  -- o trigger trg_venda_vincula já resolveu pessoa_id e inscricao_id
  if v_insc is not null then
    insert into dash.eventos (lancamento_id, inscricao_id, pessoa_id, tipo, fonte, payload, dedupe_key)
    select v_lanc, v.inscricao_id, v.pessoa_id,
           case when v.status = 'aprovada' then 'compra' else 'checkout_iniciado' end,
           'hotmart',
           jsonb_build_object('valor', v.valor_bruto, 'status', v.status),
           'venda:' || v.plataforma || ':' || v.transacao_id || ':' || v.status
    from dash.vendas v where v.id = v_venda
    on conflict (dedupe_key) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'venda_id', v_venda, 'inscricao_id', v_insc);
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS — só o service_role (usado no Worker) executa
-- ---------------------------------------------------------------------
revoke all on function public.ingest_lead(jsonb)   from public, anon, authenticated;
revoke all on function public.ingest_evento(jsonb) from public, anon, authenticated;
revoke all on function public.ingest_quiz(jsonb)   from public, anon, authenticated;
revoke all on function public.ingest_venda(jsonb)  from public, anon, authenticated;

grant execute on function public.ingest_lead(jsonb)   to service_role;
grant execute on function public.ingest_evento(jsonb) to service_role;
grant execute on function public.ingest_quiz(jsonb)   to service_role;
grant execute on function public.ingest_venda(jsonb)  to service_role;

-- ---------------------------------------------------------------------
-- 6. TESTE — simula um lead vindo do SellFlux
-- ---------------------------------------------------------------------
select public.ingest_lead('{
  "lancamento": "lanc-2026-09",
  "email": "Maria.Teste+ig@gmail.com",
  "telefone": "55 (11) 98888-7777",
  "nome": "Maria Teste",
  "origem": "sellflux",
  "utm": {"source":"fb","medium":"paid","campaign":"CAPTACAO-SET","content":"vsl-v3"},
  "meta": {"campaign_id":"1200001","adset_id":"1200002","ad_id":"1200003"},
  "dedupe_key": "sellflux:teste-001",
  "payload": {"form":"captura-set"}
}'::jsonb);

select public.ingest_quiz('{
  "lancamento": "lanc-2026-09",
  "email": "maria.teste@gmail.com",
  "respostas": [
    {"chave":"faturamento","valor":"10k_30k","label":"R$10k a R$30k","pontos":40},
    {"chave":"tempo_mercado","valor":"1_3_anos","label":"1 a 3 anos","pontos":35}
  ],
  "dedupe_key": "quiz:teste-001"
}'::jsonb);

select * from dash.v_resumo_lancamento;
select nome, email, telefone, lead_score, lead_tier, utm_campaign, meta_ad_id
from dash.inscricoes i join dash.pessoas p on p.id = i.pessoa_id;
