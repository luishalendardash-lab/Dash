-- =====================================================================
-- 41 — REFAZER A IMPORTAÇÃO DE UM LANÇAMENTO
--
-- Apaga os leads importados de um lançamento para reimportar do zero.
-- Só mexe no que veio de importação: lead que chegou por webhook fica.
--
-- Use quando o número não bater e for mais rápido refazer do que
-- descobrir o que aconteceu.
-- =====================================================================

set search_path = dash, public;

create or replace function public.limpar_lancamento_importado(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_qtd int; v_vendas int;
begin
  if coalesce(p->>'confirmar','') <> 'LIMPAR' then
    return jsonb_build_object('ok', false, 'erro', 'envie confirmar: LIMPAR');
  end if;

  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  -- vendas ligadas a esses leads perdem o vínculo, mas continuam existindo
  update dash.vendas v set inscricao_id = null
  where v.inscricao_id in (
    select id from dash.inscricoes
    where lancamento_id = v_lanc and origem_sistema = 'importacao');

  with alvo as (
    select id from dash.inscricoes
    where lancamento_id = v_lanc and origem_sistema = 'importacao'
  ),
  a as (delete from dash.quiz_respostas_livres where inscricao_id in (select id from alvo)),
  b as (delete from dash.quiz_respostas where inscricao_id in (select id from alvo)),
  c as (delete from dash.eventos where inscricao_id in (select id from alvo)),
  d as (delete from dash.inscricoes where id in (select id from alvo) returning 1)
  select count(*) into v_qtd from d;

  -- pessoas que não sobraram em lugar nenhum
  delete from dash.pessoas p2
  where not exists (select 1 from dash.inscricoes i where i.pessoa_id = p2.id)
    and not exists (select 1 from dash.vendas v where v.pessoa_id = p2.id);

  select count(*) into v_vendas from dash.vendas where lancamento_id = v_lanc;

  return jsonb_build_object('ok', true, 'leads_apagados', v_qtd,
                            'vendas_mantidas', v_vendas);
end $$;

revoke all on function public.limpar_lancamento_importado(jsonb)
  from public, anon, authenticated;
grant execute on function public.limpar_lancamento_importado(jsonb) to service_role;

-- =====================================================================
-- COMO USAR
-- =====================================================================
--   select public.limpar_lancamento_importado('{
--     "lancamento": "fpee-2025-09", "confirmar": "LIMPAR"
--   }'::jsonb);
--
-- Depois reimporte, nesta ordem:
--   1. LEADS SIMPLES   modo "Planilha de captura"
--   2. MESTRE          modo "Planilha de captura"
-- =====================================================================

select 'pronto' as status;
