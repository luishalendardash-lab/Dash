-- =====================================================================
-- FIX 04 — DEDUPE DO EVENTO DE CAPTURA
--
-- Antes: a chave vinha do payload da origem. Sem id na origem, cada
-- reenvio virava um evento novo — 15 disparos = 15 capturas.
--
-- Agora: a chave é a própria inscrição. Uma captura por inscrição, por
-- definição. Reenvio do SellFlux, retry por timeout, clique duplo no
-- formulário: tudo cai na mesma chave.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. LIMPA OS DUPLICADOS EXISTENTES (mantém o primeiro de cada inscrição)
-- ---------------------------------------------------------------------
with ranqueados as (
  select id, row_number() over (
           partition by inscricao_id, tipo order by ocorreu_em asc, id asc
         ) as posicao
  from dash.eventos
  where tipo = 'captura' and inscricao_id is not null
)
delete from dash.eventos
where id in (select id from ranqueados where posicao > 1);

-- ---------------------------------------------------------------------
-- 2. TRAVA NO BANCO: uma captura por inscrição, sem depender da função
-- ---------------------------------------------------------------------
create unique index if not exists ux_evento_captura_por_inscricao
  on dash.eventos (inscricao_id)
  where tipo = 'captura';

-- ---------------------------------------------------------------------
-- 3. ingest_lead com a chave corrigida
-- ---------------------------------------------------------------------
create or replace function public.ingest_lead(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = dash, public
as $$
declare
  v_lanc_id uuid; v_pessoa uuid; v_insc uuid;
  v_novo boolean := false; v_quando timestamptz;
  v_utm jsonb := coalesce(p->'utm', '{}'::jsonb);
  v_meta jsonb := coalesce(p->'meta', '{}'::jsonb);
  v_extras jsonb := coalesce(p->'extras', '{}'::jsonb);
  v_fone_raw text := nullif(btrim(coalesce(p->>'telefone','')), '');
  v_payload jsonb;
begin
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

  if v_fone_raw is not null and dash.norm_phone(v_fone_raw) is null then
    v_extras := v_extras || jsonb_build_object('telefone_invalido', v_fone_raw);
  end if;

  begin
    v_pessoa := dash.upsert_pessoa(p->>'email', p->>'telefone', p->>'nome');
  exception when others then
    return jsonb_build_object('ok', false, 'erro', 'sem email/telefone validos',
                              'telefone_recebido', v_fone_raw);
  end;

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
    v_extras
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

  if v_fone_raw is not null then
    update dash.pessoas set telefone = coalesce(telefone, dash.norm_phone(v_fone_raw))
    where id = v_pessoa and telefone is null;
  end if;

  -- guarda a chave da origem no payload, mas NÃO usa ela para deduplicar
  v_payload := coalesce(p->'payload', '{}'::jsonb);
  if nullif(p->>'dedupe_key','') is not null then
    v_payload := v_payload || jsonb_build_object('origem_dedupe_key', p->>'dedupe_key');
  end if;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, ocorreu_em, fonte, payload, dedupe_key)
  values (v_lanc_id, v_pessoa, v_insc, 'captura', v_quando,
          coalesce(nullif(p->>'origem',''), 'desconhecida'),
          v_payload,
          'captura:' || v_insc::text)     -- <<< a chave é a inscrição
  on conflict do nothing;                 -- cobre dedupe_key E o índice único

  update dash.pessoas set ultimo_contato = greatest(ultimo_contato, v_quando) where id = v_pessoa;

  return jsonb_build_object('ok', true, 'novo', v_novo,
    'pessoa_id', v_pessoa, 'inscricao_id', v_insc,
    'telefone', dash.norm_phone(v_fone_raw));
end $$;

grant execute on function public.ingest_lead(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 4. CONFERE
-- ---------------------------------------------------------------------
select tipo, count(*) from dash.eventos group by tipo order by tipo;
