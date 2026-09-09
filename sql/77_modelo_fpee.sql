-- =====================================================================
-- 77 — MODELO DO QUIZ FPEE
--
-- As perguntas e respostas exatas dos lançamentos anteriores, tiradas
-- das planilhas de captura. A pontuação segue o que estava lá:
-- engenheiro eletricista vale 20, as demais formações valem 1.
--
-- A pergunta do CFT aparece só para quem não é engenheiro eletricista —
-- era o que acontecia nos dados: 631 respostas contra 3.063 leads.
-- =====================================================================

set search_path = dash, public;

insert into dash.quiz_modelos (nome, descricao, padrao, intro, perguntas)
values (
  'FPEE — padrão',
  'Quiz validado dos lançamentos do Perito da Elétrica. Formação, ocupação, renda e registro no CFT.',
  true,
  jsonb_build_object(
    'titulo', 'Falta pouco!',
    'texto', 'Responda 3 perguntas rápidas para liberar seu acesso.',
    'botao', 'Começar'
  ),
  jsonb_build_array(

    jsonb_build_object(
      'chave', 'qual_e_a_sua_formacao_na_area_eletrica',
      'enunciado', 'Qual é a sua formação na área elétrica?',
      'ordem', 1, 'tipo', 'multipla', 'obrigatoria', true,
      'opcoes', jsonb_build_array(
        -- a única opção que marca engenheiro: é ela que alimenta o CPL
        -- de engenheiro e a segmentação do lançamento inteiro
        jsonb_build_object('valor','eng_eletricista',
          'label','Sou Engenheiro Eletricista','pontos',20,'engenheiro',true),
        jsonb_build_object('valor','eng_outra',
          'label','Engenheiro de outra área','pontos',1,'engenheiro',false),
        jsonb_build_object('valor','tecnico',
          'label','Técnico/Tecnólogo','pontos',1,'engenheiro',false),
        jsonb_build_object('valor','estudante',
          'label','Estudante de Engenharia','pontos',1,'engenheiro',false),
        jsonb_build_object('valor','outro',
          'label','Outro','pontos',0,'engenheiro',false)
      )
    ),

    jsonb_build_object(
      'chave', 'hoje_voce_trabalha_como',
      'enunciado', 'Hoje você trabalha como?',
      'ordem', 2, 'tipo', 'multipla', 'obrigatoria', true,
      'opcoes', jsonb_build_array(
        jsonb_build_object('valor','clt','label','Funcionário de empresa','pontos',1),
        jsonb_build_object('valor','empresario','label','Empresário','pontos',1),
        jsonb_build_object('valor','autonomo','label','Empresário/Autônomo','pontos',1),
        jsonb_build_object('valor','publico','label','Funcionário Público','pontos',1),
        jsonb_build_object('valor','desempregado','label','Desempregado','pontos',0),
        jsonb_build_object('valor','aposentado','label','Aposentado','pontos',0)
      )
    ),

    jsonb_build_object(
      'chave', 'qual_sua_faixa_de_renda_hoje',
      'enunciado', 'Qual sua faixa de renda hoje?',
      'ordem', 3, 'tipo', 'multipla', 'obrigatoria', true,
      'opcoes', jsonb_build_array(
        jsonb_build_object('valor','ate3','label','Até 3mil/mês','pontos',1),
        jsonb_build_object('valor','3a5','label','Entre 3 e 5mil/mês','pontos',1),
        jsonb_build_object('valor','5a10','label','Entre 5 e 10mil/mês','pontos',2),
        jsonb_build_object('valor','mais10','label','Mais de 10mil/mês','pontos',3)
      )
    ),

    jsonb_build_object(
      'chave', 'voce_possui_registro_no_cft',
      'enunciado', 'Você possui registro no CFT?',
      'ordem', 4, 'tipo', 'multipla', 'obrigatoria', false,
      'ajuda', 'Conselho Federal dos Técnicos Industriais',
      -- só para quem não é engenheiro eletricista: para o engenheiro a
      -- pergunta não faz sentido, e nos dados ela só aparecia para os
      -- demais (631 respostas em 3.063 leads)
      'condicao', jsonb_build_object(
        'chave','qual_e_a_sua_formacao_na_area_eletrica',
        'valores', jsonb_build_array('tecnico','estudante','eng_outra','outro')
      ),
      'opcoes', jsonb_build_array(
        jsonb_build_object('valor','sim','label','SIM','pontos',2),
        jsonb_build_object('valor','nao','label','NÃO','pontos',0)
      )
    )

  )
)
on conflict (nome) do update set
  descricao = excluded.descricao,
  perguntas = excluded.perguntas,
  intro = excluded.intro,
  padrao = excluded.padrao,
  atualizado = now();

select nome, jsonb_array_length(perguntas) as perguntas, padrao
from dash.quiz_modelos;
