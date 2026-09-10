-- =====================================================================
-- 83 — MANYCHAT: O CAMINHO QUE COBRE OS DOIS CASOS
--
-- O gatilho "Novo contato" funciona, mas só para quem nunca existiu.
-- Lead que já está no ManyChat — e num lançamento recorrente isso é a
-- maioria — nunca aciona esse gatilho.
--
-- A tag alcança os dois. Por isso a dash agora aplica sempre uma, e
-- reaplica quando o contato já existia: remover e pôr de novo faz o
-- gatilho disparar outra vez.
--
-- Uma automação com gatilho de tag substitui as duas configurações.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  campos = '[]'::jsonb,
  passos = jsonb_build_array(
    'No Worker, configure MANYCHAT_TOKEN com a API Key. É a única variável '
      || 'obrigatória.',

    'Opcional: MANYCHAT_TAG com o nome da tag. Sem ela a dash usa "dash-lead".',

    'No ManyChat, crie a automação de WhatsApp com o gatilho "Tag aplicada" '
      || '(Tag Applied), apontando para essa tag.',

    'Use o gatilho de TAG, não o de "Novo contato". O de novo contato só '
      || 'dispara para quem nunca existiu — e num lançamento recorrente a '
      || 'maior parte dos leads já está no ManyChat de meses anteriores.',

    'O primeiro bloco da automação precisa ser um WhatsApp Message Template '
      || 'aprovado. Contato que nunca respondeu está fora da janela de 24 '
      || 'horas e só recebe template.',

    'Deixe MANYCHAT_FLOW vazio. O disparo por sendFlow falha em contato que '
      || 'nunca interagiu.',

    'Teste duas vezes: com um número novo e com um que já está no ManyChat. '
      || 'Os dois precisam receber — é justamente o segundo caso que o '
      || 'gatilho de novo contato não cobre.'
  ),
  instrucoes = 'A dash cria o contato com opt-in de WhatsApp ou, se ele já '
    || 'existir, atualiza o opt-in. Depois aplica a tag — reaplicando quando o '
    || 'contato já existia, para o gatilho disparar de novo. A automação do '
    || 'ManyChat, acionada pela tag, envia o template.'
where slug = 'manychat_api';

select 'pronto' as status;
