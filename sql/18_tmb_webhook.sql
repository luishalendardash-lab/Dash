-- =====================================================================
-- 18 — TMB POR WEBHOOK
--
-- A TMB tem webhook de vendas: notifica na hora quando o pedido é
-- efetivado ou cancelado. Passa a ser a forma principal; a API fica
-- como reserva para buscar histórico.
--
-- Um detalhe que muda o faturamento: a TMB manda dois valores.
--   valor_principal = ticket do produto (o que o produtor fatura)
--   valor_total     = o que o aluno paga, com juros do financiamento
-- No exemplo da documentação: principal R$ 397, total R$ 1.997.
-- A receita usa o principal. Usar o total inflaria o faturamento em 5x.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  direcao = 'entrada',
  fonte_webhook = 'tmb',
  instrucoes = 'A TMB avisa a dash na hora em que o pedido é efetivado ou cancelado. Ela permite cadastrar até 3 URLs, então dá para manter outras integrações que já existam junto com esta.',
  passos = '[
    "No portal do produtor, vá em PRODUTOS > Mais opções do produto > Integrações > Webhook Vendas.",
    "Em URL, cole o endereço abaixo.",
    "Em Chave, escreva exatamente: x-dash-token",
    "Em Valor, cole o token que aparece no campo abaixo (é o mesmo segredo dos outros webhooks da dash).",
    "Marque o Status como ativo e salve.",
    "Repita para cada produto que você vende pela TMB — a configuração é por produto, não por conta.",
    "Depois de uma venda, confira em Histórico de interações se a entrega saiu com sucesso."
  ]'::jsonb,
  campos = '[
    {"chave":"header_valor","rotulo":"Valor do header x-dash-token","tipo":"senha","obrigatorio":false,
     "dica":"Use o mesmo segredo que aparece na URL do webhook",
     "ajuda":"Se preencher aqui, a dash passa a recusar avisos que não tragam esse valor. Deixe em branco para aceitar sem conferir."},
    {"chave":"token","rotulo":"Token da API (opcional)","tipo":"senha","obrigatorio":false,
     "dica":"Portal do produtor > Produtos > TMB API",
     "ajuda":"Só é necessário para importar vendas antigas, anteriores à ativação do webhook."}
  ]'::jsonb
where slug = 'tmb';

-- ---------------------------------------------------------------------
-- A TMB parcela: o pedido nasce efetivado e as parcelas seguem depois.
-- Guardamos o valor com juros no raw para conferência, mas ele não entra
-- na receita.
-- ---------------------------------------------------------------------
comment on column dash.vendas.valor_bruto is
  'Valor que o produtor fatura. Na TMB é o valor_principal, nao o valor_total (que inclui juros do financiamento).';

-- ---------------------------------------------------------------------
-- CONFERE
-- ---------------------------------------------------------------------
select slug, nome, direcao, coalesce(fonte_webhook,'(consulta)') as entrada,
       jsonb_array_length(passos) as passos
from dash.integracoes
where categoria = 'venda'
order by ordem;
