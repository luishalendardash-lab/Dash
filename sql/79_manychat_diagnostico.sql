-- =====================================================================
-- 79 — ESTADO DO MANYCHAT
--
-- O log mostrou onde estamos:
--
--   busca do contato    funciona (achou o subscriber 956180079)
--   criação de contato  "Validation error" — a trava de conta
--   sendFlow            "Subscriber is not active" — regra do ManyChat
--
-- Os dois últimos têm soluções diferentes: a criação depende do suporte
-- liberar; o disparo se resolve com tag, sem depender de ninguém.
-- =====================================================================

set search_path = dash, public;

create or replace function public.estado_manychat(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_build_object(
    'integracao_ativa', (
      select ativa from dash.integracoes where slug = 'manychat_api'),

    -- o que aconteceu nas últimas tentativas, agrupado por tipo
    'ultimas_tentativas', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'tipo', tipo, 'quantidade', n, 'ultimo', ultimo, 'exemplo', exemplo
      ) order by ultimo desc), '[]'::jsonb)
      from (
        select
          case
            when erro like '%Validation error%' then 'criacao recusada'
            when erro like '%not active%' then 'fluxo recusado (contato inativo)'
            when erro like '%TOKEN%' then 'token ausente'
            when erro like '%tag%' then 'tag falhou'
            else 'outro'
          end as tipo,
          count(*) as n,
          max(recebido_em) as ultimo,
          left(max(erro), 120) as exemplo
        from dash.webhooks_raw
        where fonte like '%manychat%'
          and recebido_em > now() - interval '30 days'
        group by 1
      ) t
    ),

    -- contatos que a dash conseguiu criar ou encontrar
    'contatos_alcancados', (
      select count(distinct body->>'subscriber_id')
      from dash.webhooks_raw
      where fonte like '%manychat%' and body->>'subscriber_id' is not null),

    'leads_do_lancamento_atual', (
      select count(*) from dash.inscricoes i
      join dash.lancamentos l on l.id = i.lancamento_id
      where l.status in ('captacao','aquecimento','evento','carrinho')),

    'diagnostico', jsonb_build_object(
      'busca_funciona', exists (
        select 1 from dash.webhooks_raw
        where fonte like '%manychat%' and body->>'subscriber_id' is not null),
      'criacao_bloqueada', exists (
        select 1 from dash.webhooks_raw
        where fonte like '%manychat%' and erro like '%Validation error%'),
      'fluxo_recusado', exists (
        select 1 from dash.webhooks_raw
        where fonte like '%manychat%' and erro like '%not active%')
    )
  ) into v_res;

  return v_res;
end $$;

revoke all on function public.estado_manychat(jsonb) from public, anon, authenticated;
grant execute on function public.estado_manychat(jsonb) to service_role;

notify pgrst, 'reload schema';

select jsonb_pretty(public.estado_manychat('{}'::jsonb));
