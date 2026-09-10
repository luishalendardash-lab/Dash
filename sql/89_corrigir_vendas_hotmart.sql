-- =====================================================================
-- 89 — CORRIGIR AS VENDAS DA HOTMART JÁ RECEBIDAS
--
-- O parser lia o payload procurando cada campo "em qualquer lugar" do
-- JSON. No formato v2 da Hotmart isso encontrava a coisa errada:
--
--   price é um objeto { value, currency_value } — a busca pulava
--   objetos, então o valor virava zero
--
--   name existe em buyer E em product — achava o do comprador
--   primeiro, e o nome do comprador virava o nome do produto
--
--   event "PURCHASE_APPROVED" era lido como status, não batia com
--   nenhuma chave, e toda venda virava "pendente"
--
-- O corpo de cada webhook ficou guardado em vendas.raw. Dá para
-- reconstruir tudo a partir dele, sem pedir reenvio.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O ESTRAGO
-- ---------------------------------------------------------------------
select
  count(*) as vendas_hotmart,
  count(*) filter (where coalesce(valor_bruto, 0) = 0) as sem_valor,
  count(*) filter (where status = 'pendente') as marcadas_pendentes,
  count(*) filter (where produto is null) as sem_produto,
  round(coalesce(sum(valor_bruto), 0), 2) as faturamento_hoje
from dash.vendas
where plataforma = 'hotmart';

-- ---------------------------------------------------------------------
-- 2. RECONSTRUIR A PARTIR DO PAYLOAD GUARDADO
-- ---------------------------------------------------------------------
create or replace function public.corrigir_vendas_hotmart(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  r record; d jsonb; compra jsonb; j_produto jsonb; comprador jsonb;
  v_valor numeric; v_liquido numeric; v_status text; v_bruto text;
  v_produto text; v_metodo text; v_quando timestamptz;
  v_qtd int := 0; v_valor_antes numeric; v_valor_depois numeric := 0;
begin
  select coalesce(sum(valor_bruto), 0) into v_valor_antes
  from dash.vendas where plataforma = 'hotmart';

  for r in
    select id, raw, transacao_id from dash.vendas
    where plataforma = 'hotmart'
      and raw is not null
      and jsonb_typeof(raw) = 'object'
    limit coalesce(nullif(p->>'limite','')::int, 5000)
  loop
    d := coalesce(r.raw->'data', r.raw);
    compra := coalesce(d->'purchase', '{}'::jsonb);
    j_produto := coalesce(d->'product', '{}'::jsonb);
    comprador := coalesce(d->'buyer', d->'user', '{}'::jsonb);

    -- o valor está em price.value, não em price
    v_valor := coalesce(
      dash.valor_para_numero(compra->'price'->>'value'),
      dash.valor_para_numero(compra->'full_price'->>'value'),
      dash.valor_para_numero(r.raw->>'price'),
      0
    );

    -- o que fica com o produtor, entre as comissões
    select coalesce(dash.valor_para_numero(c->>'value'), 0) into v_liquido
    from jsonb_array_elements(
      case when jsonb_typeof(d->'commissions') = 'array'
           then d->'commissions' else '[]'::jsonb end) c
    where upper(coalesce(c->>'source','')) = 'PRODUCER'
    limit 1;

    v_bruto := lower(coalesce(
      compra->>'status', d->>'status', r.raw->>'status',
      replace(upper(coalesce(r.raw->>'event','')), 'PURCHASE_', ''), ''));

    v_status := case
      when v_bruto ~ '(approv|complet|paid)' then 'aprovada'
      when v_bruto ~ '(refund)' then 'reembolsada'
      when v_bruto ~ '(chargeback|protest)' then 'chargeback'
      when v_bruto ~ '(cancel|expired|blocked)' then 'cancelada'
      when v_bruto ~ '(billet|waiting|started|analis|analys|overdue|delayed)' then 'pendente'
      else null
    end;

    -- o nome do produto, nunca o do comprador
    v_produto := nullif(btrim(coalesce(
      j_produto->>'name', j_produto->>'product_name', r.raw->>'prod_name')), '');

    v_metodo := lower(coalesce(compra->'payment'->>'type', compra->>'payment_type', ''));
    v_metodo := case
      when v_metodo ~ 'pix' then 'pix'
      when v_metodo ~ '(billet|boleto|bank_slip)' then 'boleto'
      when v_metodo ~ '(credit|card|cartao)' then 'cartao'
      else nullif(v_metodo, '')
    end;

    v_quando := coalesce(
      dash.texto_para_data(compra->>'approved_date'),
      dash.texto_para_data(compra->>'order_date'),
      dash.texto_para_data(r.raw->>'creation_date')
    );

    update dash.vendas set
      -- só sobrescreve quando o payload traz algo melhor
      valor_bruto = case when v_valor > 0 then v_valor else dash.vendas.valor_bruto end,
      valor_liquido = case when coalesce(v_liquido,0) > 0
                           then v_liquido else dash.vendas.valor_liquido end,
      produto = coalesce(v_produto, dash.vendas.produto),
      status = coalesce(v_status, dash.vendas.status),
      metodo = coalesce(v_metodo, dash.vendas.metodo),
      parcelas = coalesce(nullif(compra->'payment'->>'installments_number','')::int, dash.vendas.parcelas),
      oferta = coalesce(nullif(compra->'offer'->>'code',''), dash.vendas.oferta),
      email_comprador = coalesce(nullif(comprador->>'email',''), dash.vendas.email_comprador),
      fone_comprador = coalesce(nullif(comprador->'checkout_phone'->>'number',''),
                                nullif(comprador->>'phone',''), dash.vendas.fone_comprador),
      ocorreu_em = coalesce(v_quando, dash.vendas.ocorreu_em)
    where id = r.id;

    v_qtd := v_qtd + 1;
  end loop;

  select coalesce(sum(valor_bruto), 0) into v_valor_depois
  from dash.vendas where plataforma = 'hotmart';

  return jsonb_build_object(
    'ok', true,
    'vendas_revisadas', v_qtd,
    'faturamento_antes', round(v_valor_antes, 2),
    'faturamento_depois', round(v_valor_depois, 2),
    'recuperado', round(v_valor_depois - v_valor_antes, 2),
    'aprovadas', (select count(*) from dash.vendas
                  where plataforma = 'hotmart' and status = 'aprovada'),
    'ainda_sem_valor', (select count(*) from dash.vendas
                        where plataforma = 'hotmart' and coalesce(valor_bruto,0) = 0)
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. LIGAR A VENDA AO LEAD PELO E-MAIL
--    Venda sem pessoa não aparece na atribuição por criativo.
-- ---------------------------------------------------------------------
create or replace function public.religar_vendas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_pessoas int; v_inscricoes int;
begin
  with liga as (
    update dash.vendas v set pessoa_id = p2.id
    from dash.pessoas p2
    where v.pessoa_id is null
      and v.email_comprador is not null
      and p2.email = dash.norm_email(v.email_comprador)
    returning 1
  )
  select count(*) into v_pessoas from liga;

  with liga2 as (
    update dash.vendas v set
      inscricao_id = i.id,
      lancamento_id = coalesce(v.lancamento_id, i.lancamento_id)
    from dash.inscricoes i
    where v.inscricao_id is null
      and v.pessoa_id = i.pessoa_id
      and i.capturado_em <= v.ocorreu_em
    returning 1
  )
  select count(*) into v_inscricoes from liga2;

  -- o lead que comprou fica marcado, para o funil e o CPA
  update dash.inscricoes i set comprou = true
  from dash.vendas v
  where v.inscricao_id = i.id
    and v.status = 'aprovada'
    and not coalesce(i.comprou, false);

  return jsonb_build_object('ok', true,
    'vendas_ligadas_a_pessoa', v_pessoas,
    'vendas_ligadas_a_inscricao', v_inscricoes);
end $$;

revoke all on function public.corrigir_vendas_hotmart(jsonb), public.religar_vendas(jsonb)
  from public, anon, authenticated;
grant execute on function public.corrigir_vendas_hotmart(jsonb), public.religar_vendas(jsonb)
  to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 4. RODAR
-- ---------------------------------------------------------------------
select jsonb_pretty(public.corrigir_vendas_hotmart('{}'::jsonb));
select jsonb_pretty(public.religar_vendas('{}'::jsonb));
