-- =====================================================================
-- 16 — CATÁLOGO DE INTEGRAÇÕES
--
-- Cada plataforma traz: passos numerados, campos de credencial e, quando
-- ela permite montar o corpo do webhook, o JSON pronto para colar.
-- Tudo vem do banco, então adicionar plataforma nova não exige mexer no
-- código do front.
-- =====================================================================

set search_path = dash, public;

alter table dash.integracoes
  add column if not exists passos jsonb not null default '[]',
  add column if not exists campos jsonb not null default '[]',
  add column if not exists snippet text,
  add column if not exists snippet_rotulo text,
  add column if not exists ajuda_url text;

-- ---------------------------------------------------------------------
-- HOTMART
-- ---------------------------------------------------------------------
update dash.integracoes set
  passos = '[
    "No painel da Hotmart, abra Ferramentas > Webhook (Notificações) e clique em Cadastrar webhook.",
    "Cole a URL abaixo no campo de destino e escolha a versão 2.0 do payload.",
    "Marque os eventos: compra aprovada, compra cancelada, reembolso e chargeback. Se vender assinatura, marque também os eventos de assinatura.",
    "Salve. A Hotmart vai mostrar um código chamado Hottok — copie e cole aqui embaixo.",
    "Use o botão de teste da própria Hotmart para disparar um evento e confira se a bolinha desta integração fica verde."
  ]'::jsonb,
  campos = '[
    {"chave":"hottok","rotulo":"Hottok","tipo":"senha","obrigatorio":true,
     "dica":"O código que a Hotmart mostra depois de salvar o webhook",
     "ajuda":"Sem ele, qualquer um que descubra a URL poderia registrar vendas falsas."}
  ]'::jsonb,
  instrucoes = 'A Hotmart envia cada venda automaticamente. O Hottok é a assinatura que prova que o aviso veio mesmo dela.',
  ajuda_url = 'https://ajuda.hotmart.com'
where slug = 'hotmart';

-- ---------------------------------------------------------------------
-- KIWIFY
-- ---------------------------------------------------------------------
update dash.integracoes set
  fonte_webhook = 'kiwify',
  passos = '[
    "No painel da Kiwify, abra Apps > Webhooks e clique em Criar Webhook.",
    "Cole a URL abaixo no campo de URL.",
    "Em Produtos, selecione todos (assim produto novo já entra sem reconfigurar).",
    "Em Eventos, marque: compra aprovada, compra recusada, reembolso e chargeback. Se vender assinatura, marque também cancelada, atrasada e renovada.",
    "Salve e use o botão Testar Webhook. Depois confira em Ver logs se a entrega saiu com sucesso."
  ]'::jsonb,
  campos = '[
    {"chave":"token","rotulo":"Token do webhook","tipo":"senha","obrigatorio":false,
     "dica":"Opcional — a Kiwify mostra ao criar o webhook",
     "ajuda":"Se preenchido, a dash confere a assinatura de cada aviso."}
  ]'::jsonb,
  instrucoes = 'A Kiwify manda os valores em centavos; a dash converte sozinha.',
  ajuda_url = 'https://ajuda.kiwify.com.br/pt-br/article/como-funcionam-os-webhooks-2ydtgl/'
where slug = 'kiwify';

-- ---------------------------------------------------------------------
-- HERO SPARK — permite montar o corpo, então entregamos pronto
-- ---------------------------------------------------------------------
insert into dash.integracoes (slug, nome, categoria, emoji, cor, direcao, fonte_webhook, ordem)
values ('herospark', 'HeroSpark', 'venda', '⚡', '#5B2CFF', 'entrada', 'herospark', 3)
on conflict (slug) do nothing;

update dash.integracoes set
  nome = 'HeroSpark', categoria = 'venda', emoji = '⚡', cor = '#5B2CFF',
  direcao = 'entrada', fonte_webhook = 'herospark', ordem = 3,
  passos = '[
    "No menu lateral da HeroSpark, clique em Piloto Automático e depois em Usar modelo de automação.",
    "Escolha o modelo Pagamento Confirmado e clique em Usar este modelo.",
    "No campo Ação a ser realizada, selecione Gerar um Webhook.",
    "Em Filtro de Disparo, escolha Aplicar em todos os produtos.",
    "Em Edição de Webhook: cole a URL abaixo, mantenha o método POST e adicione o header Content-Type com o valor application/json.",
    "No campo Body, cole exatamente o JSON abaixo — ele já traz as variáveis da HeroSpark nos nomes que a dash entende.",
    "Salve a edição e ative a automação no topo da página.",
    "Repita para os modelos de reembolso e cancelamento, se quiser acompanhar esses eventos."
  ]'::jsonb,
  campos = '[]'::jsonb,
  snippet_rotulo = 'Body do webhook — cole no campo Body da automação',
  snippet = '{
  "evento": "PURCHASE_APPROVED",
  "transacao": "{{ payment_id }}",
  "nome": "{{ buyer_name }}",
  "email": "{{ buyer_email }}",
  "telefone": "{{ buyer_phone_ddi }}{{ buyer_phone }}",
  "produto": "{{ product_name }}",
  "produto_id": "{{ product_id }}",
  "valor": "{{ payment_total }}",
  "metodo": "{{ payment_method }}"
}',
  instrucoes = 'A HeroSpark deixa você montar o corpo do aviso. Cole o JSON abaixo e não precisa mexer em mais nada — os nomes já batem com o que a dash espera. Troque o valor de "evento" em cada automação: PURCHASE_APPROVED, PURCHASE_REFUNDED, PURCHASE_CANCELED ou PURCHASE_CHARGEBACK.',
  ajuda_url = 'https://ajuda.herospark.com'
where slug = 'herospark';

-- ---------------------------------------------------------------------
-- GURU — mantém, mas com passos
-- ---------------------------------------------------------------------
update dash.integracoes set
  fonte_webhook = 'guru', ordem = 4,
  passos = '[
    "No Digital Manager Guru, abra Configurações > Webhooks e clique em Novo webhook.",
    "Cole a URL abaixo e selecione os eventos de transação (aprovada, cancelada, reembolsada).",
    "Salve e dispare um evento de teste."
  ]'::jsonb
where slug = 'guru';

-- ---------------------------------------------------------------------
-- DEMAIS — passos das que já existiam
-- ---------------------------------------------------------------------
update dash.integracoes set
  ordem = 5,
  passos = '[
    "Saída: cole abaixo a URL de POST do formulário do SellFlux. É para lá que a dash manda cada lead capturado, disparando a sequência de e-mail.",
    "Para achar essa URL: abra o formulário no SellFlux, veja o código de incorporação e copie o endereço que aparece no action do formulário.",
    "Entrada (opcional): cadastre a URL de webhook abaixo no SellFlux para espelhar tags e mudanças de etapa na dash."
  ]'::jsonb,
  campos = '[
    {"chave":"endpoint","rotulo":"URL de POST do formulário","tipo":"texto","obrigatorio":true,
     "dica":"https://webhook.sellflux.app/v2/webhook/form/..."}
  ]'::jsonb
where slug = 'sellflux';

update dash.integracoes set
  ordem = 6,
  passos = '[
    "No SendFlow, abra a configuração de webhooks do grupo.",
    "Cole a URL abaixo nos eventos de entrada e saída de participante.",
    "Assim a dash passa a saber quem realmente entrou no grupo, e não só quem clicou no link."
  ]'::jsonb
where slug = 'sendflow';

update dash.integracoes set
  ordem = 7,
  passos = '[
    "Saída: cole abaixo o endereço do webhook que recebe o lead e o encaminha ao ManyChat.",
    "Entrada (opcional): no fluxo do ManyChat, adicione uma ação External Request apontando para a URL abaixo, para registrar mensagem enviada e resposta do lead."
  ]'::jsonb,
  campos = '[
    {"chave":"webhook","rotulo":"Webhook que recebe o lead","tipo":"texto","obrigatorio":true,
     "dica":"https://..."}
  ]'::jsonb
where slug = 'manychat';

update dash.integracoes set
  ordem = 8,
  passos = '[
    "Crie um usuário do sistema no Business Manager e dê a ele acesso às contas de anúncio.",
    "Gere um token com as permissões ads_read e business_management, sem prazo de expiração.",
    "Cadastre esse token como secret META_TOKEN no Worker.",
    "Coloque o código do lançamento no início do nome de cada campanha que faz parte dele."
  ]'::jsonb
where slug = 'meta-ads';

update dash.integracoes set ordem = 9 where slug = 'youtube';

-- ---------------------------------------------------------------------
-- LISTAGEM — agora devolve passos, campos e snippet
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
    from dash.webhooks_raw w where w.fonte = i.fonte_webhook
  ) a on true;

  return jsonb_build_object('ok', true, 'integracoes', coalesce(v_res, '[]'::jsonb));
end $$;

grant execute on function public.dash_integracoes(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- PLATAFORMAS DE VENDA — para o card de receita da home
-- ---------------------------------------------------------------------
insert into dash.plataformas (slug, nome, inicial, cor, taxa_percentual, taxa_fixa, ordem) values
  ('herospark', 'HeroSpark', 'H', '#5B2CFF', 9.9, 1.00, 5)
on conflict (slug) do nothing;

select slug, nome, ordem, jsonb_array_length(passos) as passos
from dash.integracoes order by ordem;
