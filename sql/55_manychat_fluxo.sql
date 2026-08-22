-- =====================================================================
-- 55 — DISPARAR O FLUXO DO MANYCHAT
--
-- Duas descobertas do primeiro teste:
--
-- 1. addTagByName só funciona com tag que JÁ EXISTE na conta. Na
--    primeira vez ela não existe e a chamada falha em silêncio. Agora a
--    dash cria a tag e tenta de novo.
--
-- 2. Contato criado por API NÃO dispara gatilho de "novo contato" no
--    ManyChat. Esses gatilhos valem para quem chega por WhatsApp, link
--    ou comentário. Por API, o contato entra inscrito e para por ali —
--    era o que acontecia também no fluxo do n8n.
--
--    Para ele receber a mensagem, o fluxo precisa ser chamado pelo ID.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  campos = jsonb_build_array(
    jsonb_build_object(
      'chave','token','rotulo','Token da API','tipo','senha','obrigatorio',true,
      'dica','1234567:abcdef...',
      'ajuda','ManyChat > Settings > API > API Key. Deixe vazio para usar o secret MANYCHAT_TOKEN do Worker.'),
    jsonb_build_object(
      'chave','flow_ns','rotulo','Fluxo ao entrar','tipo','texto','obrigatorio',false,
      'dica','content20240101000000_123456',
      'ajuda','O ID do fluxo. Sem ele o contato é criado mas não recebe mensagem: contato criado por API não dispara gatilho de novo contato.'),
    jsonb_build_object(
      'chave','tag','rotulo','Tag ao entrar','tipo','texto','obrigatorio',false,
      'dica','entrada-lead',
      'ajuda','Se a tag não existir no ManyChat, a dash cria.'),
    jsonb_build_object(
      'chave','campo_lancamento','rotulo','Campo do lançamento','tipo','texto',
      'obrigatorio',false, 'dica','lancamento',
      'ajuda','Opcional. Campo personalizado que recebe o código do lançamento, para o fluxo se ramificar.')
  ),
  passos = jsonb_build_array(
    'No ManyChat, vá em Settings > API e copie a API Key. Cole no campo Token.',
    'Abra o fluxo que deve receber os leads. Na URL do navegador, o trecho depois de '
      || '/cms/ é o ID do fluxo — algo como content20240101000000_123456.',
    'Cole esse ID no campo Fluxo ao entrar.',
    'IMPORTANTE: contato criado por API não dispara o gatilho de "novo contato". '
      || 'Sem o ID do fluxo aqui, o contato é criado mas não recebe mensagem nenhuma.',
    'A tag é opcional. Se o seu fluxo se ramifica por tag, escreva o nome — a dash cria '
      || 'a tag caso ela ainda não exista.',
    'Faça um lead de teste e confira no ManyChat se a conversa começou.'
  ),
  instrucoes = 'A dash cria o contato no ManyChat pela API e dispara o fluxo que você '
    || 'indicar. Se o telefone já existir, ela encontra o contato em vez de duplicar. '
    || 'Falha de token, de tag ou de fluxo aparece em Ajustes > Últimos erros.'
where slug = 'manychat_api';

select slug, nome from dash.integracoes where slug = 'manychat_api';
