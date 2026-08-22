-- =====================================================================
-- 54 — MANYCHAT DIRETO, SEM O n8n
--
-- Hoje o caminho é dash → n8n → ManyChat. O n8n só faz o que a dash pode
-- fazer sozinha: cria o contato ou, se já existe, procura pelo telefone.
--
-- Tirar a peça do meio ganha duas coisas:
--   uma falha a menos para acontecer
--   o erro aparece na dash, em vez de morrer em silêncio no n8n
--
-- O caminho antigo continua: se o token direto não estiver configurado,
-- a dash usa o webhook do n8n como antes.
-- =====================================================================

set search_path = dash, public;

insert into dash.integracoes
  (slug, nome, categoria, emoji, cor, ativa, direcao, ordem,
   campos, config, passos, instrucoes, ajuda_url)
values (
  'manychat_api', 'ManyChat (direto)', 'whatsapp', '💬', '#00b3a4', false, 'saida', 8,
  jsonb_build_array(
    jsonb_build_object(
      'chave','token','rotulo','Token da API','tipo','senha','obrigatorio',true,
      'dica','1234567:abcdef...',
      'ajuda','ManyChat > Settings > API > API Key. Cole só o token, sem a palavra Bearer.'),
    jsonb_build_object(
      'chave','tag','rotulo','Tag ao entrar','tipo','texto','obrigatorio',false,
      'dica','entrada-lead',
      'ajuda','Deixe vazio se o seu fluxo dispara quando o contato é criado.'),
    jsonb_build_object(
      'chave','campo_lancamento','rotulo','Campo do lançamento','tipo','texto',
      'obrigatorio',false, 'dica','lancamento',
      'ajuda','Opcional. Campo personalizado do ManyChat que recebe o código do lançamento, para o fluxo se ramificar.')
  ),
  '{}'::jsonb,
  jsonb_build_array(
    'No ManyChat, vá em Settings > API e copie a API Key.',
    'Cole no campo Token da API e salve.',
    'Se o seu fluxo de WhatsApp dispara quando o contato é criado, deixe a Tag vazia.',
    'Se ele dispara por tag, escreva o nome exato — a dash aplica logo após criar o contato.',
    'Faça um lead de teste pela landing e confira no ManyChat se o contato apareceu.',
    'Ao ativar isto, o repasse pelo n8n deixa de ser usado.'
  ),
  'A dash cria o contato no ManyChat direto pela API. Se o telefone já existir, ela '
  || 'encontra o contato e reaproveita, em vez de duplicar — mesma lógica que o n8n fazia, '
  || 'sem a peça do meio. Falha de token ou de tag aparece na tela de Ajustes.',
  'https://api.manychat.com/swagger'
)
on conflict (slug) do update set
  nome = excluded.nome, campos = excluded.campos,
  passos = excluded.passos, instrucoes = excluded.instrucoes,
  ajuda_url = excluded.ajuda_url;

-- o caminho pelo n8n ganha o aviso de que os dois não rodam juntos
update dash.integracoes
set instrucoes = instrucoes
  || ' Se o ManyChat (direto) estiver ativo, este repasse é ignorado.'
where slug = 'manychat'
  and instrucoes not like '%ignorado%';

select slug, nome, ativa from dash.integracoes where slug like 'manychat%' order by ordem;
