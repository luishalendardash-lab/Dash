-- =====================================================================
-- 53 — APAGAR UM LANÇAMENTO
--
-- Para o caso de criar errado. Apaga o lançamento e tudo que pende dele:
-- inscrições, eventos, quiz, aulas, dados de anúncio.
--
-- As VENDAS não são apagadas: o dinheiro entrou de verdade e continua
-- no faturamento do negócio. Elas apenas perdem o vínculo com o
-- lançamento e passam a aparecer como "fora de lançamento".
--
-- Duas travas, porque isso não tem volta:
--   confirmação com o nome exato do lançamento
--   recusa se houver venda ligada, a não ser que você insista
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O QUE SERIA APAGADO
--    Sempre chame isto antes: mostra o estrago sem fazer nada.
-- ---------------------------------------------------------------------
create or replace function public.previa_apagar_lancamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_nome text; v_codigo text;
begin
  select id, nome, codigo into v_lanc, v_nome, v_codigo
  from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  return jsonb_build_object(
    'ok', true,
    'nome', v_nome,
    'codigo', v_codigo,
    'leads', (select count(*) from dash.inscricoes where lancamento_id = v_lanc),
    'eventos', (select count(*) from dash.eventos where lancamento_id = v_lanc),
    'vendas', (select count(*) from dash.vendas where lancamento_id = v_lanc),
    'receita', (select coalesce(round(sum(valor_bruto),2),0) from dash.vendas
                where lancamento_id = v_lanc and status = 'aprovada'),
    'aulas', (select count(*) from dash.aulas where lancamento_id = v_lanc),
    'perguntas_quiz', (select count(*) from dash.quiz_perguntas
                       where lancamento_id = v_lanc),
    'anuncios', (select count(*) from dash.ads_entidades where lancamento_id = v_lanc),
    'investimento', (select coalesce(round(sum(gasto),2),0) from dash.ads_insights
                     where lancamento_id = v_lanc),
    'aviso', case
      when (select count(*) from dash.vendas where lancamento_id = v_lanc) > 0
        then 'Este lancamento tem vendas. Elas NAO serao apagadas: continuam no '
           || 'faturamento, mas ficam sem lancamento.'
      else 'Nenhuma venda ligada a este lancamento.' end
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. APAGAR
--    p: { lancamento, confirmar: '<nome exato>' }
-- ---------------------------------------------------------------------
create or replace function public.apagar_lancamento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_nome text;
  v_leads int; v_vendas int; v_soltas int; v_pessoas int;
begin
  select id, nome into v_lanc, v_nome
  from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  -- o nome exato é a trava: evita apagar o lançamento errado por engano
  if btrim(coalesce(p->>'confirmar','')) <> btrim(v_nome) then
    return jsonb_build_object('ok', false,
      'erro', 'para apagar, envie confirmar com o nome exato: ' || v_nome);
  end if;

  -- não deixa apagar o único lançamento: a dash ficaria sem contexto
  if (select count(*) from dash.lancamentos) <= 1 then
    return jsonb_build_object('ok', false,
      'erro', 'este e o unico lancamento. Crie outro antes de apagar este.');
  end if;

  select count(*) into v_vendas from dash.vendas where lancamento_id = v_lanc;

  -- as vendas sobrevivem: o dinheiro entrou de verdade
  update dash.vendas set lancamento_id = null, inscricao_id = null
  where lancamento_id = v_lanc;
  v_soltas := v_vendas;

  -- e tudo que só existe por causa do lançamento vai junto
  delete from dash.quiz_respostas_livres
  where inscricao_id in (select id from dash.inscricoes where lancamento_id = v_lanc);

  delete from dash.quiz_respostas
  where inscricao_id in (select id from dash.inscricoes where lancamento_id = v_lanc);

  delete from dash.eventos where lancamento_id = v_lanc;

  with a as (delete from dash.inscricoes where lancamento_id = v_lanc returning 1)
  select count(*) into v_leads from a;

  delete from dash.ads_insights where lancamento_id = v_lanc;
  delete from dash.ads_entidades where lancamento_id = v_lanc;
  delete from dash.ads_candidatas where lancamento_id = v_lanc;
  delete from dash.aulas where lancamento_id = v_lanc;
  delete from dash.quiz_perguntas where lancamento_id = v_lanc;

  delete from dash.lancamentos where id = v_lanc;

  -- pessoa que só existia por causa deste lançamento não precisa ficar
  with p2 as (
    delete from dash.pessoas p3
    where not exists (select 1 from dash.inscricoes i where i.pessoa_id = p3.id)
      and not exists (select 1 from dash.vendas v where v.pessoa_id = p3.id)
    returning 1
  )
  select count(*) into v_pessoas from p2;

  return jsonb_build_object(
    'ok', true, 'apagado', v_nome,
    'leads_apagados', v_leads,
    'pessoas_apagadas', v_pessoas,
    'vendas_preservadas', v_soltas
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.previa_apagar_lancamento(jsonb), public.apagar_lancamento(jsonb)
  from public, anon, authenticated;
grant execute on function public.previa_apagar_lancamento(jsonb),
  public.apagar_lancamento(jsonb) to service_role;

select 'pronto' as status;
