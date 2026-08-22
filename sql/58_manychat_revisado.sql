-- =====================================================================
-- 58 — MANYCHAT: INSTRUÇÕES CORRIGIDAS
--
-- Depois de ler a documentação e os relatos da comunidade, três coisas
-- explicam as falhas que vimos:
--
-- 1. Criar contato de WhatsApp por API vem BLOQUEADO por padrão na
--    conta. O erro aparece como "Validation error" genérico, mas o
--    motivo real é "Permission denied to import wa_id". Só o suporte
--    do ManyChat libera, por ticket.
--
-- 2. Contato do canal WhatsApp não é encontrado por findBySystemField
--    nem por findByCustomField no campo padrão. A saída é manter um
--    campo personalizado espelho com o número — era exatamente o que o
--    fluxo do n8n fazia com o field_id 13528011.
--
-- 3. sendFlow exige contato ativo. Contato novo que nunca interagiu
--    está inativo. A mensagem tem que sair por automação com gatilho de
--    tag, que consegue enviar template para contato inativo.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  campos = '[]'::jsonb,
  passos = jsonb_build_array(
    'ANTES DE TUDO: abra um ticket em help.manychat.com pedindo para habilitar '
      || '"import contacts via API" na sua conta. Sem isso, criar contato de '
      || 'WhatsApp pela API retorna erro de validação — é uma trava contra spam, '
      || 'liberada só manualmente por eles.',
    'No ManyChat, crie um campo personalizado de texto chamado wa_number '
      || '(Settings > Custom Fields). Ele guarda o número e é o único jeito de '
      || 'reencontrar o contato depois: contato de WhatsApp não aparece nas buscas '
      || 'normais da API.',
    'Anote o ID desse campo — aparece na URL quando você o abre.',
    'Configure as variáveis no Worker (Settings > Variables and Secrets): '
      || 'MANYCHAT_TOKEN com a API Key, MANYCHAT_FIELD_ID com o ID do campo, '
      || 'MANYCHAT_CAMPO_FONE com wa_number e MANYCHAT_TAG com a tag de entrada.',
    'No ManyChat, monte a automação do lançamento com gatilho "Tag aplicada", '
      || 'usando essa mesma tag. NÃO use gatilho de novo contato: contato criado '
      || 'por API não dispara esse gatilho.',
    'A primeira mensagem da automação precisa ser um Message Template aprovado. '
      || 'Contato novo está fora da janela de 24 horas e só recebe template.',
    'Deixe MANYCHAT_FLOW vazio. O disparo por sendFlow falha em contato que nunca '
      || 'interagiu ("Subscriber is not active") — a tag resolve isso.',
    'Marque esta integração como ativa e teste com um número que nunca conversou '
      || 'com o seu ManyChat.'
  ),
  instrucoes = 'A dash procura o contato pelo campo espelho, cria se não existir, '
    || 'grava o número e o lançamento nos campos personalizados e aplica a tag. '
    || 'A automação do ManyChat, disparada pela tag, envia a mensagem. '
    || 'Cada passo fica registrado em Ajustes > Últimos erros quando falha.'
where slug = 'manychat_api';

select slug, nome, ativa from dash.integracoes where slug = 'manychat_api';
