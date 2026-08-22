-- =====================================================================
-- 56 — MANYCHAT SEM CAMPOS NA TELA
--
-- Token e fluxo vivem nas variáveis do Worker. Repetir os campos na tela
-- só cria chance de erro: um clique em Salvar com o campo preenchido por
-- engano passa a valer sobre a variável.
--
-- Este arquivo limpa o que ficou salvo e deixa a integração com apenas
-- o liga-desliga.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  -- sem campos: nada para preencher, nada para errar
  campos = '[]'::jsonb,

  -- limpa o que ficou salvo antes. Havia uma tag "l0726" gravada por
  -- engano nos campos opcionais; se ficasse, seria aplicada em todo lead.
  segredos = '{}'::jsonb,
  config = '{}'::jsonb,

  passos = jsonb_build_array(
    'Este atalho é configurado no Worker, não aqui.',
    'Em Settings > Variables and Secrets do Worker, crie MANYCHAT_TOKEN '
      || '(tipo Secret) com a API Key do ManyChat.',
    'Crie também MANYCHAT_FLOW (tipo Text) com o ID do fluxo que recebe os leads. '
      || 'O ID está na URL do fluxo, depois de /cms/.',
    'Volte aqui e marque como ativa.',
    'Ao ativar, o repasse pelo n8n deixa de ser usado.',
    'Teste com um número que nunca conversou com o seu ManyChat: com um número '
      || 'que já falou, a janela de 24 horas está aberta e o teste passa mesmo '
      || 'que o template esteja errado.'
  ),

  instrucoes = 'A dash cria o contato no ManyChat pela API e dispara o fluxo indicado '
    || 'em MANYCHAT_FLOW. Se o telefone já existir, ela encontra o contato em vez de '
    || 'duplicar. Contato criado por API não dispara gatilho de "novo contato" — por '
    || 'isso o fluxo é chamado pelo ID. Falhas aparecem em Ajustes > Últimos erros.'

where slug = 'manychat_api';

select slug, nome, ativa, campos from dash.integracoes where slug = 'manychat_api';
