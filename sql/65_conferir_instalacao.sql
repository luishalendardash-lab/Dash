-- =====================================================================
-- 65 — O QUE ESTÁ FALTANDO
--
-- Erro "Could not find the function X in the schema cache" quer dizer
-- que algum arquivo SQL não foi executado. Em vez de descobrir um por
-- vez conforme os botões falham, isto confere tudo de uma vez e diz
-- exatamente qual arquivo rodar.
--
-- Rode e me mande o resultado, ou rode os arquivos que ele apontar.
-- =====================================================================

set search_path = dash, public;

with esperadas(funcao, arquivo) as (values
  ('ingest_lead',                '02_rpc_ingest.sql'),
  ('ingest_venda',               '02_rpc_ingest.sql'),
  ('dash_receita',               '06_dash_home.sql'),
  ('dash_captura',               '06_dash_home.sql'),
  ('dash_anuncios',              '11_tela_anuncios.sql'),
  ('salvar_quiz',                '12_quiz.sql'),
  ('dash_vendas',                '14_vendas.sql'),
  ('salvar_integracao',          '15_integracoes.sql'),
  ('integracao_segredo',         '15_integracoes.sql'),
  ('ingest_pagamentos',          '20_tmb_simples.sql'),
  ('dash_aulas',                 '21_aulas.sql'),
  ('dash_produtos',              '23_produtos.sql'),
  ('dash_ajustes',               '26_ajustes.sql'),
  ('importar_leads',             '30_importar.sql'),
  ('importar_vendas',            '30_importar.sql'),
  ('dash_recorrencia',           '32_tags_recorrencia.sql'),
  ('importar_tags_padrao',       '33_tags_padrao.sql'),
  ('importar_captura',           '36_planilhas_captura.sql'),
  ('lancar_gasto_manual',        '37_desempenho_criativo.sql'),
  ('ingest_ads_historico',       '38_ads_historico.sql'),
  ('ads_para_buscar',            '38_ads_historico.sql'),
  ('diagnostico_leads',          '39_diagnostico.sql'),
  ('mover_leads',                '40_consertar_importacao.sql'),
  ('limpar_lancamento_importado','41_refazer_lancamento.sql'),
  ('processar_import',           '43_import_supabase.sql'),
  ('processar_vendas',           '45_import_vendas.sql'),
  ('dash_resumo_lancamento',     '49_painel_lancamento.sql'),
  ('dash_serie_diaria',          '50_serie_lancamento.sql'),
  ('candidatas_do_lancamento',   '51_campanhas_periodo.sql'),
  ('escolher_campanhas',         '51_campanhas_periodo.sql'),
  ('campanhas_escolhidas',       '51_campanhas_periodo.sql'),
  ('processar_campanhas',        '52_import_campanhas_csv.sql'),
  ('apagar_lancamento',          '53_apagar_lancamento.sql'),
  ('previa_apagar_lancamento',   '53_apagar_lancamento.sql'),
  ('ingest_investimento',        '59_investimento_auto.sql'),
  ('periodo_investimento',       '59_investimento_auto.sql'),
  ('webhooks_pendentes',         '61_reprocessar.sql'),
  ('reprocessar_vendas',         '61_reprocessar.sql'),
  ('salvar_contas_meta',         '62_contas_globais.sql'),
  ('contas_meta',                '62_contas_globais.sql'),
  ('pagamentos_pendentes',       '64_recuperacao.sql'),
  ('alvos_recuperacao',          '64_recuperacao.sql'),
  ('registrar_recuperacao',      '64_recuperacao.sql')
)
select
  e.arquivo as rode_este_arquivo,
  string_agg(e.funcao, ', ' order by e.funcao) as funcoes_faltando
from esperadas e
where not exists (
  select 1 from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = e.funcao
)
group by e.arquivo
order by e.arquivo;

-- ---------------------------------------------------------------------
-- Se a consulta acima não devolver nada, está tudo instalado.
-- Nesse caso o problema é o cache do PostgREST — o comando abaixo o
-- recarrega sem precisar reiniciar nada.
-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';

select 'cache recarregado. Se ainda faltar funcao, rode os arquivos acima.' as observacao;
