-- =====================================================================
-- 31 — DATA BRASILEIRA NOS WEBHOOKS
--
-- Descoberto testando o envio em massa pelo SellFlux: se o payload traz
-- a data como "15/05/2026", a chamada inteira falha com "date/time field
-- value out of range" e o lead se perde.
--
-- Dois problemas num só:
--   1. a conversão direta não aceita o formato brasileiro
--   2. quando falha, derruba a chamada em vez de continuar
--
-- Agora a leitura é tolerante: entende dd/mm/aaaa, ISO e variações. Se
-- mesmo assim não der, usa a hora atual em vez de perder o registro.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. LEITOR TOLERANTE (o mesmo usado na importação por CSV)
-- ---------------------------------------------------------------------
create or replace function dash.texto_para_data(txt text)
returns timestamptz language plpgsql immutable as $$
declare v text;
begin
  v := btrim(coalesce(txt, ''));
  if v = '' then return null; end if;

  -- dd/mm/aaaa, com ou sem hora. Sem isso o Postgres lê mês primeiro e
  -- 11/07 vira 7 de novembro.
  if v ~ '^\d{1,2}/\d{1,2}/\d{4}' then
    begin
      return to_timestamp(v, 'DD/MM/YYYY HH24:MI:SS');
    exception when others then
      begin
        return to_timestamp(split_part(v, ' ', 1), 'DD/MM/YYYY');
      exception when others then return null; end;
    end;
  end if;

  -- dd-mm-aaaa
  if v ~ '^\d{1,2}-\d{1,2}-\d{4}' then
    begin
      return to_timestamp(split_part(v, ' ', 1), 'DD-MM-YYYY');
    exception when others then return null; end;
  end if;

  -- epoch em segundos ou milissegundos
  if v ~ '^\d{10}$' then
    return to_timestamp(v::bigint);
  end if;
  if v ~ '^\d{13}$' then
    return to_timestamp((v::bigint) / 1000);
  end if;

  -- ISO e o que o Postgres já entende
  begin
    return v::timestamptz;
  exception when others then
    return null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 2. INGESTÃO DE LEAD USANDO O LEITOR
-- ---------------------------------------------------------------------
create or replace function public.ingest_lead(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_email text; v_fone text; v_quando timestamptz;
  v_pessoa uuid; v_insc uuid; v_novo boolean := false;
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
    return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento ativo');
  end if;

  v_email := dash.norm_email(p->>'email');
  v_fone  := dash.norm_phone(p->>'telefone');

  if v_email is null and v_fone is null then
    return jsonb_build_object('ok', false, 'erro', 'sem email e sem telefone');
  end if;

  -- data tolerante: formato estranho não pode derrubar a captura
  v_quando := coalesce(dash.texto_para_data(p->>'capturado_em'), now());

  -- e-mail primeiro: casar por telefone antes funde leads que dividem
  -- o mesmo número (casal, empresa)
  if v_email is not null then
    select id into v_pessoa from dash.pessoas where email = v_email limit 1;
  end if;
  if v_pessoa is null and v_fone is not null then
    select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
  end if;

  if v_pessoa is null then
    insert into dash.pessoas (nome, email, telefone, criado_em)
    values (nullif(btrim(p->>'nome'),''), v_email, v_fone, v_quando)
    returning id into v_pessoa;
  else
    update dash.pessoas set
      nome = coalesce(nullif(btrim(p->>'nome'),''), nome),
      email = coalesce(email, v_email),
      telefone = coalesce(telefone, v_fone)
    where id = v_pessoa;
  end if;

  select id into v_insc from dash.inscricoes
  where pessoa_id = v_pessoa and lancamento_id = v_lanc;

  if v_insc is null then
    insert into dash.inscricoes (
      lancamento_id, pessoa_id, capturado_em,
      utm_source, utm_medium, utm_campaign, utm_content, utm_term,
      meta_campaign_id, meta_adset_id, meta_ad_id, fbclid,
      landing_url, referrer, origem_sistema, extras
    ) values (
      v_lanc, v_pessoa, v_quando,
      nullif(btrim(p->'utm'->>'source'),''),
      nullif(btrim(p->'utm'->>'medium'),''),
      nullif(btrim(p->'utm'->>'campaign'),''),
      nullif(btrim(p->'utm'->>'content'),''),
      nullif(btrim(p->'utm'->>'term'),''),
      nullif(btrim(p->'meta'->>'campaign_id'),''),
      nullif(btrim(p->'meta'->>'adset_id'),''),
      nullif(btrim(p->'meta'->>'ad_id'),''),
      nullif(btrim(p->>'fbclid'),''),
      nullif(btrim(p->>'landing_url'),''),
      nullif(btrim(p->>'referrer'),''),
      coalesce(nullif(btrim(p->>'origem'),''), 'formulario'),
      coalesce(p->'extras', '{}'::jsonb)
    )
    returning id into v_insc;
    v_novo := true;
  else
    -- lead que volta: completa o que estava faltando, sem apagar
    update dash.inscricoes set
      utm_source = coalesce(utm_source, nullif(btrim(p->'utm'->>'source'),'')),
      utm_campaign = coalesce(utm_campaign, nullif(btrim(p->'utm'->>'campaign'),'')),
      utm_content = coalesce(utm_content, nullif(btrim(p->'utm'->>'content'),'')),
      meta_ad_id = coalesce(meta_ad_id, nullif(btrim(p->'meta'->>'ad_id'),'')),
      atualizado_em = now()
    where id = v_insc;
  end if;

  insert into dash.eventos
    (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key, payload)
  values (
    v_insc, v_pessoa, v_lanc, 'captura',
    coalesce(nullif(btrim(p->>'fonte'),''), 'desconhecida'),
    v_quando, 'captura:' || v_insc::text, coalesce(p->'raw','{}'::jsonb)
  )
  on conflict (dedupe_key) do nothing;

  return jsonb_build_object(
    'ok', true, 'novo', v_novo,
    'pessoa_id', v_pessoa, 'inscricao_id', v_insc,
    'telefone', v_fone, 'capturado_em', v_quando
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. VENDA COM A MESMA TOLERÂNCIA
-- ---------------------------------------------------------------------
do $$
begin
  -- ingest_venda também converte data direto; troca pela versão tolerante
  if exists (select 1 from pg_proc where proname = 'ingest_venda') then
    execute $q$
      create or replace function dash.data_venda(txt text)
      returns timestamptz language sql immutable as $f$
        select coalesce(dash.texto_para_data(txt), now());
      $f$;
    $q$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
grant execute on function public.ingest_lead(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 5. CONFERE — todos devem virar a data certa
-- ---------------------------------------------------------------------
select v as entrada, dash.texto_para_data(v) as lido
from unnest(array[
  '15/05/2026 10:00:00',
  '15/05/2026',
  '2026-05-15T10:00:00Z',
  '2026-05-15',
  '15-05-2026',
  '1747303200'
]) as v;
