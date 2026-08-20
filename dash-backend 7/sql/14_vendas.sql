-- =====================================================================
-- 14 — VENDAS
--
-- A pergunta que essa tela responde: de qual anúncio veio quem comprou.
-- O cruzamento é por e-mail e telefone do comprador contra os leads.
-- Venda que não casa com nenhum lead aparece como "sem atribuição" —
-- não some, porque esconder isso inflaria a taxa de acerto.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. RECONCILIAÇÃO
--    O trigger já amarra na entrada. Isto reprocessa o histórico, útil
--    quando um lead se cadastra DEPOIS de comprar (acontece: compra pelo
--    e-mail pessoal e se inscreve com outro, ou vice-versa).
-- ---------------------------------------------------------------------
create or replace function public.reconciliar_vendas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_ok int := 0; v_orfas int;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  -- tenta achar a pessoa pelo e-mail ou telefone normalizado
  with alvo as (
    select v.id, v.email_comprador, v.fone_comprador, v.lancamento_id
    from dash.vendas v
    where v.pessoa_id is null
      and (v_lanc is null or v.lancamento_id = v_lanc)
  ),
  achou as (
    select a.id as venda_id, p.id as pessoa_id
    from alvo a
    join dash.pessoas p
      on (p.email = dash.norm_email(a.email_comprador) and a.email_comprador is not null)
      or (p.telefone = dash.norm_phone(a.fone_comprador) and a.fone_comprador is not null)
  ),
  atualiza as (
    update dash.vendas v
    set pessoa_id = a.pessoa_id,
        inscricao_id = (
          select i.id from dash.inscricoes i
          where i.pessoa_id = a.pessoa_id and i.lancamento_id = v.lancamento_id
          limit 1
        )
    from achou a
    where v.id = a.venda_id
    returning 1
  )
  select count(*) into v_ok from atualiza;

  -- marca como compradores os leads que fecharam
  update dash.inscricoes i
  set comprou = true,
      comprou_em = coalesce(i.comprou_em, v.ocorreu_em),
      etapa = 'comprou',
      atualizado_em = now()
  from dash.vendas v
  where v.inscricao_id = i.id
    and v.status = 'aprovada'
    and not i.comprou;

  select count(*) into v_orfas
  from dash.vendas where pessoa_id is null and (v_lanc is null or lancamento_id = v_lanc);

  return jsonb_build_object('ok', true, 'vinculadas', v_ok, 'ainda_sem_lead', v_orfas);
end $$;

-- ---------------------------------------------------------------------
-- 2. TELA DE VENDAS
-- ---------------------------------------------------------------------
create or replace function public.dash_vendas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_imposto numeric;
  v_resumo jsonb; v_origem jsonb; v_lista jsonb; v_dia jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc is null then
    select id into v_lanc from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;
  if v_lanc is null then return jsonb_build_object('ok', false, 'erro', 'nenhum lancamento'); end if;

  select coalesce((valor)::text::numeric, 0) into v_imposto
  from dash.config where chave = 'imposto_percentual';
  v_imposto := coalesce(v_imposto, 0);

  -- ---- resumo
  select jsonb_build_object(
    'aprovadas',   count(*) filter (where status = 'aprovada'),
    'pendentes',   count(*) filter (where status = 'pendente'),
    'reembolsos',  count(*) filter (where status in ('reembolsada','chargeback')),
    'bruto',       round(coalesce(sum(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'liquido',     round(coalesce(sum(
                     case when valor_liquido > 0 then valor_liquido else valor_bruto * 0.9 end
                   ) filter (where status = 'aprovada'), 0) * (1 - v_imposto/100), 2),
    'ticket',      round(coalesce(avg(valor_bruto) filter (where status = 'aprovada'), 0), 2),
    'com_lead',    count(*) filter (where status = 'aprovada' and inscricao_id is not null),
    'sem_lead',    count(*) filter (where status = 'aprovada' and inscricao_id is null),
    'valor_reembolsado', round(coalesce(sum(valor_bruto)
                     filter (where status in ('reembolsada','chargeback')), 0), 2)
  )
  into v_resumo
  from dash.vendas where lancamento_id = v_lanc;

  -- ---- de onde vieram as vendas
  with atribuido as (
    select
      coalesce(a.nome, i.utm_content, i.meta_ad_id, '(sem anuncio)') as anuncio,
      coalesce(ac.nome, i.utm_campaign, '(sem campanha)') as campanha,
      i.engenheiro,
      v.valor_bruto
    from dash.vendas v
    join dash.inscricoes i on i.id = v.inscricao_id
    left join dash.ads_entidades a on a.id = i.meta_ad_id
    left join dash.ads_entidades aj on aj.id = a.parent_id
    left join dash.ads_entidades ac on ac.id = aj.parent_id
    where v.lancamento_id = v_lanc and v.status = 'aprovada'
  )
  select jsonb_agg(x order by (x->>'receita')::numeric desc) into v_origem
  from (
    select jsonb_build_object(
      'anuncio', anuncio,
      'campanha', campanha,
      'vendas', count(*),
      'engenheiros', count(*) filter (where engenheiro),
      'receita', round(sum(valor_bruto), 2)
    ) as x
    from atribuido group by anuncio, campanha
  ) t;

  -- ---- vendas dia a dia
  select jsonb_agg(jsonb_build_object(
    'dia', dia, 'vendas', qtd, 'receita', receita
  ) order by dia)
  into v_dia
  from (
    select ocorreu_em::date as dia, count(*) qtd, round(sum(valor_bruto),2) receita
    from dash.vendas
    where lancamento_id = v_lanc and status = 'aprovada'
    group by 1
  ) d;

  -- ---- últimas vendas
  select jsonb_agg(x order by (x->>'ocorreu_em') desc) into v_lista
  from (
    select jsonb_build_object(
      'id', v.id,
      'nome', coalesce(p.nome, v.email_comprador, '—'),
      'email', coalesce(p.email, v.email_comprador),
      'produto', v.produto,
      'oferta', v.oferta,
      'status', v.status,
      'metodo', v.metodo,
      'valor', v.valor_bruto,
      'parcelas', v.parcelas,
      -- boleto parcelado: o aluno paga em parcelas, o produtor fatura o ticket
      'valor_parcela', nullif(v.raw->>'valor_parcela','')::numeric,
      'valor_entrada', nullif(v.raw->>'valor_entrada','')::numeric,
      'valor_com_juros', nullif(v.raw->>'_valor_com_juros','')::numeric,
      'status_financeiro', v.raw->>'status_financeiro',
      'ocorreu_em', v.ocorreu_em,
      'inscricao_id', v.inscricao_id,
      'campanha', i.utm_campaign,
      'anuncio', coalesce(a.nome, i.utm_content, i.meta_ad_id),
      'engenheiro', coalesce(i.engenheiro, false),
      'lead_score', i.lead_score,
      'atribuida', v.inscricao_id is not null
    ) as x
    from dash.vendas v
    left join dash.inscricoes i on i.id = v.inscricao_id
    left join dash.pessoas p on p.id = v.pessoa_id
    left join dash.ads_entidades a on a.id = i.meta_ad_id
    where v.lancamento_id = v_lanc
    order by v.ocorreu_em desc
    limit 200
  ) t;

  return jsonb_build_object(
    'ok', true,
    'resumo', coalesce(v_resumo, '{}'::jsonb),
    'origem', coalesce(v_origem, '[]'::jsonb),
    'dia_a_dia', coalesce(v_dia, '[]'::jsonb),
    'vendas', coalesce(v_lista, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.dash_vendas(jsonb), public.reconciliar_vendas(jsonb)
  from public, anon, authenticated;
grant execute on function public.dash_vendas(jsonb), public.reconciliar_vendas(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 4. CONFERE
-- ---------------------------------------------------------------------
select public.dash_vendas('{}'::jsonb);
