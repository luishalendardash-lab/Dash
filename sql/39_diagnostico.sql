-- =====================================================================
-- 39 — DIAGNÓSTICO DA IMPORTAÇÃO
--
-- Quando o número de leads de um lançamento não bate com o esperado, o
-- motivo quase sempre é um destes:
--
--   1. planilha importada com o lançamento errado no seletor
--   2. a mesma pessoa entrando duas vezes com e-mails diferentes
--   3. leads com data fora do período daquele lançamento
--
-- As consultas abaixo mostram qual é. Rode e me mande o resultado.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- ONDE CADA LEAD FOI PARAR
-- Mostra, por lançamento, em que mês os leads foram capturados.
-- Um lançamento de setembro com leads de janeiro é importação trocada.
-- ---------------------------------------------------------------------
create or replace function public.diagnostico_leads(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(x order by x->>'lancamento') into v_res
  from (
    select jsonb_build_object(
      'lancamento', l.nome,
      'slug', l.slug,
      'esperado_em', to_char(coalesce(l.captacao_inicio, l.criado_em), 'MM/YYYY'),
      'leads', count(*),
      'pessoas', count(distinct i.pessoa_id),
      'por_mes', (
        select coalesce(jsonb_agg(jsonb_build_object('mes', mes, 'leads', n)
                                  order by mes), '[]'::jsonb)
        from (
          select to_char(i2.capturado_em, 'YYYY-MM') as mes, count(*) as n
          from dash.inscricoes i2
          where i2.lancamento_id = l.id
          group by 1
          order by count(*) desc
          limit 6
        ) m
      ),
      'com_data_aproximada', count(*) filter (where i.data_aproximada),
      'com_anuncio', count(*) filter (where i.meta_ad_id is not null),
      'engenheiros', count(*) filter (where i.engenheiro)
    ) as x
    from dash.lancamentos l
    join dash.inscricoes i on i.lancamento_id = l.id
    group by l.id, l.nome, l.slug, l.captacao_inicio, l.criado_em
  ) t;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- MESMA PESSOA, DOIS CADASTROS
-- Se o mesmo telefone aparece com e-mails diferentes, viraram duas
-- pessoas — e o total de leads infla.
-- ---------------------------------------------------------------------
create or replace function public.diagnostico_duplicados(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_fone int; v_nome int; v_exemplos jsonb;
begin
  select count(*) into v_fone from (
    select telefone from dash.pessoas
    where telefone is not null group by telefone having count(*) > 1
  ) t;

  select count(*) into v_nome from (
    select lower(btrim(nome)) from dash.pessoas
    where nome is not null and btrim(nome) <> '' group by 1 having count(*) > 1
  ) t;

  select jsonb_agg(jsonb_build_object(
    'telefone', telefone, 'cadastros', n, 'emails', emails
  )) into v_exemplos
  from (
    select telefone, count(*) as n,
           jsonb_agg(coalesce(email, '(sem email)')) as emails
    from dash.pessoas
    where telefone is not null
    group by telefone having count(*) > 1
    order by count(*) desc limit 5
  ) t;

  return jsonb_build_object(
    'ok', true,
    'telefones_repetidos', v_fone,
    'nomes_repetidos', v_nome,
    'total_pessoas', (select count(*) from dash.pessoas),
    'exemplos', coalesce(v_exemplos, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- MOVER LEADS DE UM LANÇAMENTO PARA OUTRO
-- Para consertar importação feita no lançamento errado, sem apagar nada.
-- Move só os que foram capturados dentro do intervalo informado.
--   p: { de: 'fpee-2025-09', para: 'fpee-2026-01',
--        data_de: '2026-01-01', data_ate: '2026-01-31' }
-- ---------------------------------------------------------------------
create or replace function public.mover_leads(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_de uuid; v_para uuid; v_d1 date; v_d2 date;
  v_movidos int := 0; v_conflito int := 0;
begin
  select id into v_de from dash.lancamentos where slug = p->>'de';
  select id into v_para from dash.lancamentos where slug = p->>'para';
  if v_de is null or v_para is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  v_d1 := nullif(p->>'data_de','')::date;
  v_d2 := nullif(p->>'data_ate','')::date;

  -- quem já tem inscrição no destino não pode ser movido: viraria
  -- duplicata. Esses são apagados da origem em vez de movidos.
  with conflitantes as (
    select i.id from dash.inscricoes i
    where i.lancamento_id = v_de
      and (v_d1 is null or i.capturado_em::date >= v_d1)
      and (v_d2 is null or i.capturado_em::date <= v_d2)
      and exists (select 1 from dash.inscricoes j
                  where j.pessoa_id = i.pessoa_id and j.lancamento_id = v_para)
  ),
  apaga as (
    delete from dash.inscricoes where id in (select id from conflitantes) returning 1
  )
  select count(*) into v_conflito from apaga;

  with move as (
    update dash.inscricoes set lancamento_id = v_para
    where lancamento_id = v_de
      and (v_d1 is null or capturado_em::date >= v_d1)
      and (v_d2 is null or capturado_em::date <= v_d2)
    returning 1
  )
  select count(*) into v_movidos from move;

  -- os eventos acompanham
  update dash.eventos e set lancamento_id = v_para
  from dash.inscricoes i
  where e.inscricao_id = i.id and i.lancamento_id = v_para and e.lancamento_id = v_de;

  return jsonb_build_object('ok', true, 'movidos', v_movidos,
                            'apagados_por_conflito', v_conflito);
end $$;

-- ---------------------------------------------------------------------
-- APAGAR SÓ O QUE VEIO DE UMA IMPORTAÇÃO ERRADA
--   p: { lancamento, data_de, data_ate }
-- ---------------------------------------------------------------------
create or replace function public.apagar_leads_periodo(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_qtd int;
begin
  if coalesce(p->>'confirmar','') <> 'APAGAR' then
    return jsonb_build_object('ok', false, 'erro', 'envie confirmar: APAGAR');
  end if;

  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  with alvo as (
    select id from dash.inscricoes
    where lancamento_id = v_lanc
      and (nullif(p->>'data_de','') is null
           or capturado_em::date >= (p->>'data_de')::date)
      and (nullif(p->>'data_ate','') is null
           or capturado_em::date <= (p->>'data_ate')::date)
  ),
  a as (delete from dash.quiz_respostas_livres where inscricao_id in (select id from alvo)),
  b as (delete from dash.eventos where inscricao_id in (select id from alvo)),
  c as (delete from dash.inscricoes where id in (select id from alvo) returning 1)
  select count(*) into v_qtd from c;

  delete from dash.pessoas p2
  where not exists (select 1 from dash.inscricoes i where i.pessoa_id = p2.id)
    and not exists (select 1 from dash.vendas v where v.pessoa_id = p2.id);

  return jsonb_build_object('ok', true, 'apagados', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.diagnostico_leads(jsonb), public.diagnostico_duplicados(jsonb),
  public.mover_leads(jsonb), public.apagar_leads_periodo(jsonb)
  from public, anon, authenticated;
grant execute on function public.diagnostico_leads(jsonb), public.diagnostico_duplicados(jsonb),
  public.mover_leads(jsonb), public.apagar_leads_periodo(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- RODE ISTO E ME MANDE O RESULTADO
-- ---------------------------------------------------------------------
select jsonb_pretty(public.diagnostico_leads('{}'::jsonb));
