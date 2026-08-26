-- =====================================================================
-- 61 — REPROCESSAR WEBHOOKS QUE FALHARAM
--
-- Todo webhook que chega fica guardado inteiro em webhooks_raw, mesmo
-- quando o processamento falha. Isso permite reprocessar depois de
-- corrigir a causa, sem pedir reenvio para a plataforma — que a Hotmart
-- nem faz depois de responder 400.
--
-- Só reprocessa o que falhou. O que já entrou não é tocado, e a trava de
-- duplicidade por transação segura qualquer repetição.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O QUE ESTÁ PARADO
-- ---------------------------------------------------------------------
create or replace function public.webhooks_pendentes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'fonte', fonte, 'quantidade', n, 'motivo', motivo,
    'primeiro', primeiro, 'ultimo', ultimo
  ) order by n desc)
  into v_res
  from (
    select fonte,
           count(*) as n,
           -- agrupa pelo início da mensagem: o resto varia por registro
           left(coalesce(erro, 'sem erro'), 60) as motivo,
           min(recebido_em)::date as primeiro,
           max(recebido_em)::date as ultimo
    from dash.webhooks_raw
    where not processado
    group by fonte, left(coalesce(erro, 'sem erro'), 60)
  ) t;

  return jsonb_build_object(
    'ok', true,
    'total', (select count(*) from dash.webhooks_raw where not processado),
    'grupos', coalesce(v_res, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. REPROCESSAR AS VENDAS
--    O corpo guardado é reenviado para o parser correspondente.
--    p: { fonte, limite }
-- ---------------------------------------------------------------------
create or replace function public.reprocessar_vendas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  r record; v_res jsonb; v_evento text;
  v_ok int := 0; v_ignorados int := 0; v_falhas int := 0;
  v_primeiro_erro text; v_limite int;
begin
  v_limite := coalesce(nullif(p->>'limite','')::int, 500);

  for r in
    select * from dash.webhooks_raw
    where not processado
      and fonte in ('hotmart','kiwify','herospark','guru','tmb')
      and (nullif(p->>'fonte','') is null or fonte = p->>'fonte')
    order by recebido_em
    limit v_limite
  loop
    begin
      v_evento := coalesce(r.body->>'event', '');

      -- evento de área de membros e assinatura não é venda
      if r.fonte = 'hotmart' and v_evento <> '' and v_evento not like 'PURCHASE%' then
        update dash.webhooks_raw
        set processado = true, erro = 'ignorado: ' || v_evento
        where id = r.id;
        v_ignorados := v_ignorados + 1;
        continue;
      end if;

      -- o parser de cada plataforma vive no Worker; aqui reaproveitamos
      -- o formato comum, montado a partir do corpo guardado
      v_res := public.ingest_venda(dash.corpo_para_venda(r.fonte, r.body));

      if coalesce((v_res->>'ok')::boolean, false) then
        update dash.webhooks_raw set processado = true, erro = null where id = r.id;
        v_ok := v_ok + 1;
      else
        v_falhas := v_falhas + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro, v_res->>'erro');
      end if;

    exception when others then
      v_falhas := v_falhas + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true, 'reprocessadas', v_ok, 'ignoradas', v_ignorados,
    'falharam', v_falhas, 'primeiro_erro', v_primeiro_erro,
    'ainda_pendentes', (select count(*) from dash.webhooks_raw where not processado)
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. TRADUZIR O CORPO DE CADA PLATAFORMA
--    Versão reduzida do que o Worker faz, suficiente para reprocessar.
-- ---------------------------------------------------------------------
create or replace function dash.corpo_para_venda(p_fonte text, b jsonb)
returns jsonb language plpgsql immutable as $$
declare d jsonb; c jsonb;
begin
  if p_fonte in ('hotmart','guru') then
    d := coalesce(b->'data', b);
    c := coalesce(d->'buyer', d->'user', '{}'::jsonb);
    return jsonb_build_object(
      'plataforma', p_fonte,
      'transacao_id', coalesce(d->'purchase'->>'transaction',
                               d->>'transaction', b->>'id'),
      'ocorreu_em', coalesce(d->'purchase'->>'order_date',
                             d->'purchase'->>'approved_date',
                             b->>'creation_date'),
      'email', c->>'email',
      'telefone', coalesce(c->'checkout_phone'->>'number', c->>'phone'),
      'nome', c->>'name',
      'produto', coalesce(d->'product'->>'name', d->>'product_name'),
      'oferta', coalesce(d->'purchase'->'offer'->>'code', d->>'offer'),
      'status', lower(coalesce(d->'purchase'->>'status', b->>'event', 'aprovada')),
      'valor_bruto', coalesce(d->'purchase'->'price'->>'value',
                              d->'purchase'->'full_price'->>'value'),
      'valor_liquido', d->'commissions'->0->'value',
      'sck', coalesce(d->'purchase'->>'sckPaymentLink', d->>'sck'),
      'raw', b
    );
  end if;

  if p_fonte = 'kiwify' then
    return jsonb_build_object(
      'plataforma', 'kiwify',
      'transacao_id', coalesce(b->>'order_id', b->'order'->>'id'),
      'ocorreu_em', coalesce(b->>'created_at', b->'order'->>'created_at'),
      'email', coalesce(b->'Customer'->>'email', b->'customer'->>'email'),
      'telefone', coalesce(b->'Customer'->>'mobile', b->'customer'->>'phone'),
      'nome', coalesce(b->'Customer'->>'full_name', b->'customer'->>'name'),
      'produto', coalesce(b->'Product'->>'product_name', b->'product'->>'name'),
      'status', lower(coalesce(b->>'order_status', 'aprovada')),
      'valor_bruto', coalesce(b->'Commissions'->>'charge_amount', b->>'amount'),
      'raw', b
    );
  end if;

  -- formato genérico: serve para herospark, tmb e o que vier
  return jsonb_build_object(
    'plataforma', p_fonte,
    'transacao_id', coalesce(b->>'transaction_id', b->>'id', b->>'order_id'),
    'ocorreu_em', coalesce(b->>'created_at', b->>'date', b->>'ocorreu_em'),
    'email', coalesce(b->>'email', b->'customer'->>'email'),
    'telefone', coalesce(b->>'phone', b->'customer'->>'phone'),
    'nome', coalesce(b->>'name', b->'customer'->>'name'),
    'produto', coalesce(b->>'product', b->'product'->>'name'),
    'status', lower(coalesce(b->>'status', 'aprovada')),
    'valor_bruto', coalesce(b->>'value', b->>'amount', b->>'price'),
    'raw', b
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. MARCAR COMO RESOLVIDO SEM REPROCESSAR
--    Para o que nunca vai dar certo — evento antigo, teste, lixo.
-- ---------------------------------------------------------------------
create or replace function public.arquivar_webhooks(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_qtd int;
begin
  if coalesce(p->>'confirmar','') <> 'ARQUIVAR' then
    return jsonb_build_object('ok', false, 'erro', 'envie confirmar: ARQUIVAR');
  end if;

  with a as (
    update dash.webhooks_raw
    set processado = true,
        erro = coalesce(erro, '') || ' [arquivado sem reprocessar]'
    where not processado
      and (nullif(p->>'fonte','') is null or fonte = p->>'fonte')
      and (nullif(p->>'ate','') is null or recebido_em::date <= (p->>'ate')::date)
    returning 1
  )
  select count(*) into v_qtd from a;

  return jsonb_build_object('ok', true, 'arquivados', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.webhooks_pendentes(jsonb), public.reprocessar_vendas(jsonb),
  public.arquivar_webhooks(jsonb) from public, anon, authenticated;
grant execute on function public.webhooks_pendentes(jsonb), public.reprocessar_vendas(jsonb),
  public.arquivar_webhooks(jsonb) to service_role;

select jsonb_pretty(public.webhooks_pendentes('{}'::jsonb));
