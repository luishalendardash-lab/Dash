-- =====================================================================
-- FIX 03 — NORMALIZAÇÃO DE TELEFONE
--
-- Problema: a versão anterior devolvia NULL em silêncio para qualquer
-- formato fora do esperado. Telefone perdido = lead que não cruza com
-- Hotmart nem com ManyChat na hora da venda.
--
-- Agora: valida DDD real, tenta recuperar números com DDI torto, e
-- quando desiste, guarda o valor original para auditoria.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- DDDs que existem de verdade no Brasil
-- ---------------------------------------------------------------------
create or replace function dash.ddd_valido(ddd text)
returns boolean language sql immutable as $$
  select ddd in (
    '11','12','13','14','15','16','17','18','19',
    '21','22','24','27','28',
    '31','32','33','34','35','37','38',
    '41','42','43','44','45','46','47','48','49',
    '51','53','54','55',
    '61','62','63','64','65','66','67','68','69',
    '71','73','74','75','77','79',
    '81','82','83','84','85','86','87','88','89',
    '91','92','93','94','95','96','97','98','99'
  );
$$;

-- ---------------------------------------------------------------------
-- norm_phone v2
-- ---------------------------------------------------------------------
create or replace function dash.norm_phone(raw text)
returns text language plpgsql immutable as $$
declare d text; ddd text; num text; cand text;
begin
  if raw is null then return null; end if;

  d := regexp_replace(raw, '\D', '', 'g');
  if d = '' then return null; end if;

  -- zeros de operadora / prefixo internacional (00)
  d := regexp_replace(d, '^0+', '');

  -- caso normal: DDI 55 na frente
  if left(d, 2) = '55' and length(d) in (12, 13) then
    cand := substr(d, 3);
    if dash.ddd_valido(left(cand, 2)) then d := cand; end if;
  end if;

  -- DDI torto ou lixo na frente: tenta os últimos 11, depois os últimos 10.
  -- Só aceita se o DDD resultante existir de verdade — senão prefere
  -- devolver NULL a inventar um número errado.
  if length(d) > 11 then
    cand := right(d, 11);
    if dash.ddd_valido(left(cand, 2)) and left(cand, 3) ~ '^\d\d9$' then
      d := cand;
    else
      cand := right(d, 10);
      if dash.ddd_valido(left(cand, 2)) then d := cand; else return null; end if;
    end if;
  end if;

  if length(d) < 10 or length(d) > 11 then return null; end if;

  ddd := left(d, 2);
  num := substr(d, 3);

  if not dash.ddd_valido(ddd) then return null; end if;

  -- celular antigo (8 dígitos) ganha o 9; fixo continua com 8
  if length(num) = 8 and left(num, 1) in ('6','7','8','9') then
    num := '9' || num;
  end if;

  return '+55' || ddd || num;
end $$;

-- ---------------------------------------------------------------------
-- ingest_lead: guarda o telefone recusado em extras.telefone_invalido
-- (o resto da função é idêntico ao 02)
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

  -- veio telefone mas a normalização recusou: registra para auditoria
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

  -- se a pessoa já existia sem telefone e agora veio um válido, completa
  if v_fone_raw is not null then
    update dash.pessoas set telefone = coalesce(telefone, dash.norm_phone(v_fone_raw))
    where id = v_pessoa and telefone is null;
  end if;

  insert into dash.eventos (lancamento_id, pessoa_id, inscricao_id, tipo, ocorreu_em, fonte, payload, dedupe_key)
  values (v_lanc_id, v_pessoa, v_insc, 'captura', v_quando,
          coalesce(nullif(p->>'origem',''), 'desconhecida'),
          coalesce(p->'payload', '{}'::jsonb),
          nullif(p->>'dedupe_key',''))
  on conflict (dedupe_key) do nothing;

  update dash.pessoas set ultimo_contato = greatest(ultimo_contato, v_quando) where id = v_pessoa;

  return jsonb_build_object('ok', true, 'novo', v_novo,
    'pessoa_id', v_pessoa, 'inscricao_id', v_insc,
    'telefone', dash.norm_phone(v_fone_raw));
end $$;

grant execute on function public.ingest_lead(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- BATERIA DE TESTE — formatos que aparecem de verdade em formulário
-- ---------------------------------------------------------------------
select entrada, dash.norm_phone(entrada) as saida, esperado,
       case when dash.norm_phone(entrada) is not distinct from esperado
            then 'OK' else 'FALHOU' end as resultado
from (values
  ('5553999887766',      '+5553999887766'),  -- DDI + DDD + celular
  ('5153999887766',      '+5153999887766'),  -- DDI torto: recupera pelos ultimos 11
  ('(53) 99999-1234',    '+5553999991234'),  -- formatado, sem DDI
  ('53999991234',        '+5553999991234'),  -- limpo, sem DDI
  ('5399991234',         '+5553999991234'),  -- celular antigo, ganha o 9
  ('+55 (11) 98888-7777','+5511988887777'),  -- com mais e espacos
  ('55 11 3333-4444',    '+551133334444'),   -- fixo, nao ganha o 9
  ('0055953999887766',   '+5553999887766'),  -- zeros de operadora
  ('99999',              null),              -- curto demais
  ('00000000000',        null),              -- DDD inexistente
  ('abcdef',             null)               -- lixo
) as t(entrada, esperado);

-- quem entrou sem telefone válido (rode isso durante a captação)
select p.email, i.extras->>'telefone_invalido' as recusado, i.capturado_em
from dash.inscricoes i join dash.pessoas p on p.id = i.pessoa_id
where p.telefone is null
order by i.capturado_em desc;
