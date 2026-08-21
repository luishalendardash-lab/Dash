-- =====================================================================
-- 34 — VENDAS PELO EXPORT DA PLATAFORMA
--
-- Com o export da Hotmart e da TMB temos a data real de cada compra.
-- Isso é melhor que deduzir por tag em dois pontos:
--
--   a data da compra é exata, não aproximada
--   o valor é o real, não estimado
--
-- E permite descobrir o lançamento sozinho: a venda entra no lançamento
-- que estava vigente naquela data. Assim você sobe um arquivo único com
-- tudo, sem separar por período.
--
-- A janela de cada lançamento vai do início da captação até o início do
-- seguinte. Venda anterior ao primeiro lançamento fica sem lançamento —
-- aparece na Home, não na tela de Vendas.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. QUAL LANÇAMENTO ESTAVA VIGENTE NUMA DATA
-- ---------------------------------------------------------------------
create or replace function dash.lancamento_na_data(quando timestamptz)
returns uuid language sql stable as $$
  select l.id
  from dash.lancamentos l
  where coalesce(l.captacao_inicio, l.criado_em) <= quando
  order by coalesce(l.captacao_inicio, l.criado_em) desc
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- 2. IMPORTAR VENDAS
--    Sem 'lancamento' no corpo, descobre pela data de cada linha.
-- ---------------------------------------------------------------------
create or replace function public.importar_vendas(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc_fixo uuid; v_lanc uuid; v_linha jsonb;
  v_email text; v_fone text; v_data timestamptz; v_valor numeric;
  v_pessoa uuid; v_insc uuid; v_transacao text; v_plataforma text;
  v_novas int := 0; v_repetidas int := 0; v_erros int := 0;
  v_ligadas int := 0; v_sem_lanc int := 0; v_primeiro_erro text;
  v_por_lanc jsonb := '{}'::jsonb; v_slug text;
begin
  -- lançamento fixo é opcional: sem ele, cada venda cai no seu
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc_fixo from dash.lancamentos where slug = p->>'lancamento';
  end if;

  for v_linha in select * from jsonb_array_elements(
    case when jsonb_typeof(p->'linhas') = 'array' then p->'linhas' else '[]'::jsonb end
  )
  loop
    begin
      v_email := dash.norm_email(v_linha->>'email');
      v_fone  := dash.norm_phone(v_linha->>'telefone');

      v_data := dash.texto_para_data(v_linha->>'data');
      if v_data is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'data invalida: ' || coalesce(v_linha->>'data','(vazia)'));
        continue;
      end if;

      v_valor := dash.valor_para_numero(v_linha->>'valor');
      if v_valor is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'valor invalido: ' || coalesce(v_linha->>'valor','(vazio)'));
        continue;
      end if;

      -- o lançamento vigente na data da compra
      v_lanc := coalesce(v_lanc_fixo, dash.lancamento_na_data(v_data));
      if v_lanc is null then v_sem_lanc := v_sem_lanc + 1; end if;

      v_plataforma := coalesce(nullif(btrim(lower(v_linha->>'plataforma')),''), 'importacao');
      v_transacao := coalesce(
        nullif(btrim(v_linha->>'transacao'),''),
        'imp-' || md5(coalesce(v_email,'') || v_data::text || v_valor::text)
      );

      if exists (select 1 from dash.vendas
                 where transacao_id = v_transacao and plataforma = v_plataforma) then
        v_repetidas := v_repetidas + 1;
        continue;
      end if;

      -- procura a pessoa: e-mail primeiro, telefone como reserva
      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      v_insc := null;
      if v_pessoa is not null then
        if v_lanc is not null then
          select id into v_insc from dash.inscricoes
          where pessoa_id = v_pessoa and lancamento_id = v_lanc limit 1;
        end if;

        -- Comprou sem ter passado pela captação daquele lançamento.
        -- Primeiro tenta a participação mais recente ANTES da compra,
        -- que é a leitura mais fiel da jornada.
        if v_insc is null then
          select i.id into v_insc
          from dash.inscricoes i
          join dash.lancamentos l on l.id = i.lancamento_id
          where i.pessoa_id = v_pessoa
            and coalesce(l.captacao_inicio, l.criado_em) <= v_data
          order by coalesce(l.captacao_inicio, l.criado_em) desc
          limit 1;
        end if;

        -- Ainda sem nada: a pessoa existe na base mas todas as
        -- participações são posteriores à data da compra. Acontece
        -- quando a data do lead veio de importação antiga. Liga na
        -- participação mais próxima para não perder a atribuição.
        if v_insc is null then
          select i.id into v_insc
          from dash.inscricoes i
          join dash.lancamentos l on l.id = i.lancamento_id
          where i.pessoa_id = v_pessoa
          order by abs(extract(epoch from
                   coalesce(l.captacao_inicio, l.criado_em) - v_data))
          limit 1;
        end if;
      end if;

      insert into dash.vendas (
        lancamento_id, pessoa_id, inscricao_id, plataforma, transacao_id,
        produto, oferta, status, metodo, valor_bruto, valor_liquido,
        moeda, email_comprador, fone_comprador, src_hotmart, ocorreu_em, raw
      ) values (
        v_lanc, v_pessoa, v_insc, v_plataforma, v_transacao,
        nullif(btrim(v_linha->>'produto'),''),
        nullif(btrim(v_linha->>'oferta'),''),
        coalesce(nullif(btrim(lower(v_linha->>'status')),''), 'aprovada'),
        nullif(btrim(v_linha->>'metodo'),''),
        v_valor,
        coalesce(dash.valor_para_numero(v_linha->>'valor_liquido'), 0),
        'BRL',
        v_linha->>'email', v_linha->>'telefone',
        nullif(btrim(v_linha->>'sck'),''),
        v_data, v_linha
      );

      if v_insc is not null then
        v_ligadas := v_ligadas + 1;
        update dash.inscricoes set
          comprou = true,
          comprou_em = coalesce(comprou_em, v_data),
          etapa = 'comprou'
        where id = v_insc;
      end if;

      -- conta por lançamento, para você conferir a distribuição
      if v_lanc is not null then
        select slug into v_slug from dash.lancamentos where id = v_lanc;
        v_por_lanc := jsonb_set(v_por_lanc, array[v_slug],
          to_jsonb(coalesce((v_por_lanc->>v_slug)::int, 0) + 1));
      end if;

      v_novas := v_novas + 1;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true, 'novas', v_novas, 'ligadas_a_lead', v_ligadas,
    'repetidas', v_repetidas, 'sem_lancamento', v_sem_lanc,
    'erros', v_erros, 'primeiro_erro', v_primeiro_erro,
    'por_lancamento', v_por_lanc
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. A TAG DE COMPRA VIRA APENAS INDÍCIO
--    Com o export da plataforma, a compra vem com data e valor reais.
--    A marcação por tag fica desligada por padrão para não competir.
-- ---------------------------------------------------------------------
comment on function public.importar_tags_padrao(jsonb) is
  'Importa participacoes a partir das tags. Deixe padrao_compra vazio quando for importar as vendas pelo export da plataforma: a venda real marca o comprador com data e valor corretos.';

-- ---------------------------------------------------------------------
-- 4. LIMPAR MARCAÇÃO DE COMPRA VINDA DE TAG
--    Útil antes de importar as vendas reais.
-- ---------------------------------------------------------------------
create or replace function public.limpar_compra_por_tag(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_qtd int;
begin
  -- só as inscrições importadas que não têm venda registrada
  with alvo as (
    select i.id from dash.inscricoes i
    where i.origem_sistema = 'importacao' and i.comprou
      and not exists (select 1 from dash.vendas v where v.inscricao_id = i.id)
  ),
  limpa as (
    update dash.inscricoes set comprou = false, comprou_em = null,
           etapa = case when etapa = 'comprou' then 'engajado' else etapa end
    where id in (select id from alvo)
    returning 1
  )
  select count(*) into v_qtd from limpa;

  return jsonb_build_object('ok', true, 'limpas', v_qtd);
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.limpar_compra_por_tag(jsonb) from public, anon, authenticated;
grant execute on function public.importar_vendas(jsonb), public.limpar_compra_por_tag(jsonb)
  to service_role;

select slug, nome, coalesce(captacao_inicio, criado_em)::date as vigente_a_partir_de
from dash.lancamentos order by coalesce(captacao_inicio, criado_em);
