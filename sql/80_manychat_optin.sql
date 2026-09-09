-- =====================================================================
-- 80 — INSTRUÇÕES CERTAS DO MANYCHAT
--
-- A documentação oficial descreve o caminho, e ele é diferente do que
-- eu vinha tentando:
--
--   createSubscriber com optin_whatsapp  →  contato nasce opted-in
--   automação com gatilho "Novo contato"  →  dispara
--   condições "Opted-in through API" + "Opted-in for WhatsApp"
--   primeiro bloco: WhatsApp Message Template
--
-- Template pode ser enviado fora da janela de 24 horas — é justamente
-- para isso que ele existe. Sem o opt-in, nada disso funciona: o
-- contato entra sem consentimento e a automação não o reconhece.
--
-- Nem tag nem sendFlow são necessários nesse caminho.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  campos = '[]'::jsonb,
  passos = jsonb_build_array(
    'No Worker (Settings > Variables and Secrets), configure MANYCHAT_TOKEN '
      || 'com a API Key do ManyChat. Só isso é obrigatório.',

    'No ManyChat, crie a automação de WhatsApp com o gatilho "Novo contato" '
      || '(New contact).',

    'Nesse gatilho, adicione as condições "Opted-in through API" e '
      || '"Opted-in for WhatsApp". São elas que separam quem veio da dash de '
      || 'quem chegou por outro caminho.',

    'O primeiro bloco da automação precisa ser um WhatsApp Message Template '
      || 'aprovado. Contato novo está fora da janela de 24 horas e só recebe '
      || 'template — mensagem comum não sai.',

    'Deixe MANYCHAT_FLOW e MANYCHAT_TAG vazios. Com o gatilho de novo contato '
      || 'funcionando, nenhum dos dois é necessário.',

    'Se a criação de contato retornar "Permission denied to import wa_id", '
      || 'abra um ticket em help.manychat.com pedindo para habilitar a '
      || 'importação de contatos por API. É uma trava de conta contra spam, '
      || 'liberada manualmente por eles.',

    'Teste com um número que nunca conversou com o seu ManyChat: com um que '
      || 'já falou, a janela está aberta e o teste passa mesmo com o template '
      || 'errado.'
  ),
  instrucoes = 'A dash cria o contato no ManyChat já com opt-in de WhatsApp, o '
    || 'que faz a automação com gatilho "Novo contato" disparar sozinha. Se o '
    || 'telefone já existir, ela encontra o contato e atualiza o opt-in em vez '
    || 'de duplicar. Falhas aparecem em Ajustes > Últimos erros.'
where slug = 'manychat_api';

-- ---------------------------------------------------------------------
-- Limpa os avisos antigos de sendFlow: aquele caminho foi abandonado, e
-- deixá-los na tela de saúde esconde problema novo.
-- ---------------------------------------------------------------------
update dash.webhooks_raw
set processado = true,
    erro = coalesce(erro, '') || ' [caminho antigo, resolvido pelo opt-in]'
where fonte = 'manychat_parcial'
  and not processado
  and erro like '%not active%';

select
  (select count(*) from dash.webhooks_raw
   where fonte like '%manychat%' and not processado) as ainda_pendentes,
  (select nome from dash.integracoes where slug = 'manychat_api') as integracao;
