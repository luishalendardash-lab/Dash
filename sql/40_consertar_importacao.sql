-- =====================================================================
-- 40 — CONSERTAR A IMPORTAÇÃO
--
-- Dois problemas encontrados no diagnóstico:
--
--   1. leads com data de julho dentro do lançamento de janeiro
--      → planilha importada com o lançamento errado no seletor
--
--   2. leads com a data de hoje
--      → vieram de planilha sem coluna de data; o sistema carimbou o
--        momento da importação, o que joga todo mundo no mesmo dia e
--        destrói a curva de captação
--
-- As duas correções abaixo são seguras: não apagam quem está certo.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. LEADS SEM DATA REAL
--    Troca o carimbo de hoje pela data de início daquele lançamento e
--    marca como aproximada — que é o que ela é.
-- ---------------------------------------------------------------------
create or replace function public.corrigir_datas_de_hoje(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_qtd int := 0; v_res jsonb;
begin
  with corrige as (
    update dash.inscricoes i set
      capturado_em = coalesce(l.captacao_inicio, l.criado_em),
      data_aproximada = true
    from dash.lancamentos l
    where l.id = i.lancamento_id
      -- só o que foi carimbado na importação, não captura real de hoje
      and i.capturado_em::date >= current_date - 1
      and i.origem_sistema = 'importacao'
      and coalesce(l.captacao_inicio, l.criado_em)::date < current_date - 30
    returning i.lancamento_id
  )
  select count(*) into v_qtd from corrige;

  -- os eventos acompanham
  update dash.eventos e set ocorreu_em = i.capturado_em
  from dash.inscricoes i
  where e.inscricao_id = i.id and e.tipo = 'captura'
    and e.ocorreu_em::date >= current_date - 1
    and i.origem_sistema = 'importacao';

  select jsonb_agg(jsonb_build_object('lancamento', nome, 'leads', n) order by nome)
  into v_res
  from (
    select l.nome, count(*) as n
    from dash.inscricoes i join dash.lancamentos l on l.id = i.lancamento_id
    where i.data_aproximada group by l.nome
  ) t;

  return jsonb_build_object('ok', true, 'corrigidos', v_qtd,
                            'com_data_aproximada', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 2. LEADS NO LANÇAMENTO ERRADO
--
-- Move só o que você mandar, com período explícito. Nada automático:
-- uma pessoa pode legitimamente participar de vários lançamentos, e a
-- realocação automática por data destruiria isso.
--
--   p: { de, para, data_de, data_ate, aplicar }
--   Sem 'aplicar', apenas mostra quantos seriam movidos.
-- ---------------------------------------------------------------------
create or replace function public.mover_leads(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_de uuid; v_para uuid; v_d1 date; v_d2 date;
  v_alvo int; v_conflito int; v_movidos int := 0; v_apagados int := 0;
begin
  select id into v_de from dash.lancamentos where slug = p->>'de';
  select id into v_para from dash.lancamentos where slug = p->>'para';
  if v_de is null or v_para is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  v_d1 := nullif(p->>'data_de','')::date;
  v_d2 := nullif(p->>'data_ate','')::date;
  if v_d1 is null and v_d2 is null then
    return jsonb_build_object('ok', false,
      'erro', 'informe data_de e data_ate: mover tudo sem filtro e perigoso');
  end if;

  select count(*) into v_alvo
  from dash.inscricoes i
  where i.lancamento_id = v_de
    and (v_d1 is null or i.capturado_em::date >= v_d1)
    and (v_d2 is null or i.capturado_em::date <= v_d2);

  select count(*) into v_conflito
  from dash.inscricoes i
  where i.lancamento_id = v_de
    and (v_d1 is null or i.capturado_em::date >= v_d1)
    and (v_d2 is null or i.capturado_em::date <= v_d2)
    and exists (select 1 from dash.inscricoes j
                where j.pessoa_id = i.pessoa_id and j.lancamento_id = v_para);

  if not coalesce((p->>'aplicar')::boolean, false) then
    return jsonb_build_object('ok', true, 'simulacao', true,
      'seriam_movidos', v_alvo - v_conflito,
      'ja_existem_no_destino', v_conflito,
      'aviso', 'nada foi alterado. Envie aplicar: true para efetivar.');
  end if;

  -- quem já está no destino viraria duplicata: some da origem
  with conflitantes as (
    select i.id from dash.inscricoes i
    where i.lancamento_id = v_de
      and (v_d1 is null or i.capturado_em::date >= v_d1)
      and (v_d2 is null or i.capturado_em::date <= v_d2)
      and exists (select 1 from dash.inscricoes j
                  where j.pessoa_id = i.pessoa_id and j.lancamento_id = v_para)
  ),
  a as (delete from dash.quiz_respostas_livres where inscricao_id in (select id from conflitantes)),
  b as (delete from dash.eventos where inscricao_id in (select id from conflitantes)),
  c as (delete from dash.inscricoes where id in (select id from conflitantes) returning 1)
  select count(*) into v_apagados from c;

  with move as (
    update dash.inscricoes set lancamento_id = v_para
    where lancamento_id = v_de
      and (v_d1 is null or capturado_em::date >= v_d1)
      and (v_d2 is null or capturado_em::date <= v_d2)
    returning id
  )
  select count(*) into v_movidos from move;

  update dash.eventos e set lancamento_id = i.lancamento_id
  from dash.inscricoes i where e.inscricao_id = i.id and e.lancamento_id <> i.lancamento_id;

  return jsonb_build_object('ok', true, 'movidos', v_movidos,
                            'apagados_por_duplicata', v_apagados);
end $$;

drop function if exists public.realocar_por_data(jsonb);

-- ---------------------------------------------------------------------
-- 3. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.corrigir_datas_de_hoje(jsonb), public.mover_leads(jsonb)
  from public, anon, authenticated;
grant execute on function public.corrigir_datas_de_hoje(jsonb), public.mover_leads(jsonb)
  to service_role;

-- =====================================================================
-- COMO USAR — na ordem
-- =====================================================================
--
-- PASSO 1 — ver quantos leads de julho estão no lançamento de janeiro
--
--   select public.mover_leads('{
--     "de": "fpee-2026-01", "para": "fpee-2026-07",
--     "data_de": "2026-07-01", "data_ate": "2026-07-31"
--   }'::jsonb);
--
-- PASSO 2 — se o número fizer sentido, aplicar
--
--   select public.mover_leads('{
--     "de": "fpee-2026-01", "para": "fpee-2026-07",
--     "data_de": "2026-07-01", "data_ate": "2026-07-31",
--     "aplicar": true
--   }'::jsonb);
--
-- PASSO 3 — corrigir os leads que ficaram com a data de hoje
--
--   select public.corrigir_datas_de_hoje('{}'::jsonb);
--
-- PASSO 4 — conferir
--
--   select jsonb_pretty(public.diagnostico_leads('{}'::jsonb));
--
-- =====================================================================

select 'rode os comandos do bloco acima, na ordem' as proximo_passo;
