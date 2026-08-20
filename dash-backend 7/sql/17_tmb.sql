-- =====================================================================
-- 17 — TMB EDUCAÇÃO
--
-- Diferente das outras: a TMB não envia webhook. Ela expõe uma API de
-- consulta, então a dash pergunta de hora em hora se houve pedido novo.
-- Consequência prática: a venda aparece na dash com até 1h de atraso,
-- não em tempo real como Hotmart e Kiwify.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. INTEGRAÇÃO
-- ---------------------------------------------------------------------
insert into dash.integracoes (slug, nome, categoria, emoji, cor, direcao, fonte_webhook, ordem)
values ('tmb', 'TMB Educação', 'venda', '🎓', '#0F4C81', 'saida', null, 5)
on conflict (slug) do nothing;

update dash.integracoes set
  nome = 'TMB Educação', categoria = 'venda', emoji = '🎓', cor = '#0F4C81',
  direcao = 'saida', fonte_webhook = null, ordem = 5,
  instrucoes = 'A TMB não envia aviso automático de venda. A dash consulta a API dela de hora em hora, então os pedidos aparecem com até 1 hora de atraso — diferente da Hotmart, que chega na hora. Em compensação, a TMB devolve as UTMs de primeiro e último toque junto do pedido.',
  passos = '[
    "Acesse o portal do produtor da TMB e abra Produtos > TMB API.",
    "Copie o Token de acesso que aparece nessa tela. Se ainda não existir, clique para gerar um novo.",
    "Cole o token no campo abaixo e salve.",
    "Se você vende mais de um produto pela TMB e quer trazer só um deles, informe o ID do produto no segundo campo. Em branco, a dash traz todos.",
    "Use o botão Buscar pedidos agora para conferir se o token funciona. Depois disso a busca passa a rodar sozinha de hora em hora."
  ]'::jsonb,
  campos = '[
    {"chave":"token","rotulo":"Token de acesso","tipo":"senha","obrigatorio":true,
     "dica":"Portal do produtor > Produtos > TMB API",
     "ajuda":"Se você revogar o token na TMB, precisa colar o novo aqui, senão a busca para."},
    {"chave":"produto_id","rotulo":"ID do produto","tipo":"texto","obrigatorio":false,
     "dica":"Deixe em branco para trazer todos os produtos"}
  ]'::jsonb,
  ajuda_url = 'https://info.tmbeducacao.com.br/portal-do-produtor/central-de-ajuda/produto/integracoes/tmb-api'
where slug = 'tmb';

-- ordena as plataformas de venda: as de webhook primeiro
update dash.integracoes set ordem = 6 where slug = 'guru';
update dash.integracoes set ordem = 7 where slug = 'sellflux';
update dash.integracoes set ordem = 8 where slug = 'sendflow';
update dash.integracoes set ordem = 9 where slug = 'manychat';
update dash.integracoes set ordem = 10 where slug = 'meta-ads';
update dash.integracoes set ordem = 11 where slug = 'youtube';

-- ---------------------------------------------------------------------
-- 2. PLATAFORMA NO CARD DE RECEITA
--    A taxa da TMB vem por pedido (taxa_administracao), então o valor
--    líquido é calculado na entrada e o percentual aqui é só reserva.
-- ---------------------------------------------------------------------
insert into dash.plataformas (slug, nome, inicial, cor, taxa_percentual, taxa_fixa, ordem) values
  ('tmb', 'TMB Educação', 'T', '#0F4C81', 5.0, 0, 6)
on conflict (slug) do update set nome = excluded.nome, cor = excluded.cor;

-- ---------------------------------------------------------------------
-- 3. INTEGRAÇÃO SEM WEBHOOK PRECISA DE OUTRO SINAL DE VIDA
--    Para essas, o status vem da última venda registrada, não de
--    webhooks recebidos.
-- ---------------------------------------------------------------------
create or replace function public.dash_integracoes(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'slug', i.slug, 'nome', i.nome, 'categoria', i.categoria,
    'emoji', i.emoji, 'cor', i.cor, 'ativa', i.ativa, 'direcao', i.direcao,
    'fonte_webhook', i.fonte_webhook, 'instrucoes', i.instrucoes,
    'passos', i.passos, 'campos', i.campos,
    'snippet', i.snippet, 'snippet_rotulo', i.snippet_rotulo,
    'ajuda_url', i.ajuda_url, 'config', i.config,
    'segredos_definidos', (
      select coalesce(jsonb_object_agg(k, '••••' || right(v::text, 5)), '{}'::jsonb)
      from jsonb_each_text(i.segredos) as s(k, v) where v <> ''
    ),
    'ultimo_evento', coalesce(a.ultimo, v.ultimo),
    'eventos_7d', coalesce(a.qtd, v.qtd, 0),
    'falhas_7d', coalesce(a.falhas, 0)
  ) order by i.ordem)
  into v_res
  from dash.integracoes i
  -- integrações por webhook: sinal vem do que chegou
  left join lateral (
    select max(recebido_em) as ultimo,
           count(*) filter (where recebido_em > now() - interval '7 days') as qtd,
           count(*) filter (where recebido_em > now() - interval '7 days'
                              and processado = false) as falhas
    from dash.webhooks_raw w where w.fonte = i.fonte_webhook
  ) a on i.fonte_webhook is not null
  -- integrações por consulta: sinal vem das vendas trazidas
  left join lateral (
    select max(criado_em) as ultimo,
           count(*) filter (where criado_em > now() - interval '7 days') as qtd
    from dash.vendas ve where ve.plataforma = i.slug
  ) v on i.fonte_webhook is null;

  return jsonb_build_object('ok', true, 'integracoes', coalesce(v_res, '[]'::jsonb));
end $$;

grant execute on function public.dash_integracoes(jsonb) to service_role;

select slug, nome, ordem, direcao, coalesce(fonte_webhook,'(consulta)') as entrada
from dash.integracoes order by ordem;
