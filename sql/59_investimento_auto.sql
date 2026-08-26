-- =====================================================================
-- 59 — INVESTIMENTO AUTOMÁTICO POR LANÇAMENTO
--
-- O CSV resolveu o histórico, mas não serve para o dia a dia: ninguém
-- vai exportar planilha toda semana.
--
-- Aqui a dash busca as campanhas na API do Meta e distribui o gasto
-- pelos lançamentos usando a data no nome — [10.01.26][CAPTAÇÃO]. É o
-- padrão que você já usa, e ele é mais confiável que sigla porque não
-- depende de ninguém lembrar de escrever o código.
--
-- Regras de atribuição, na ordem:
--   1. data no nome da campanha  →  lançamento vigente naquela data
--   2. sem data no nome          →  fica de fora, e a tela mostra quais
--
-- Só campanhas de CAPTAÇÃO entram por padrão. Vendas, remarketing e
-- engajamento gastam no mesmo período mas não trazem lead novo.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. GUARDAR O QUE A API TROUXE
--    p: { campanhas: [{id, nome, conta, gasto, impressoes, cliques, dia}],
--         so_captacao: true }
-- ---------------------------------------------------------------------
create or replace function public.ingest_investimento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_item jsonb; v_data date; v_lanc uuid; v_slug text; v_chave text;
  v_gasto numeric; v_so_cap boolean; v_nome text;
  v_qtd int := 0; v_fora int := 0; v_sem_data int := 0;
  v_total numeric := 0; v_por_lanc jsonb := '{}'::jsonb;
  v_ignoradas jsonb := '[]'::jsonb;
begin
  v_so_cap := coalesce((p->>'so_captacao')::boolean, true);

  for v_item in select * from jsonb_array_elements(coalesce(p->'campanhas','[]'::jsonb))
  loop
    v_nome := coalesce(nullif(btrim(v_item->>'nome'),''), v_item->>'id');
    v_gasto := coalesce(dash.valor_para_numero(v_item->>'gasto'), 0);

    if v_gasto <= 0 then continue; end if;

    -- campanha que não é de captação não traz lead: incluir infla o CPL
    if v_so_cap and upper(translate(v_nome, 'ÇÃÁÉÍÓÚÂÊÔÕ', 'CAAEIOUAEOO'))
       not like '%CAPTACAO%' then
      v_fora := v_fora + 1;
      continue;
    end if;

    -- a data do nome manda; o dia do insight é reserva
    v_data := coalesce(dash.data_do_nome(v_nome),
                       nullif(v_item->>'dia','')::date);

    if v_data is null then
      v_sem_data := v_sem_data + 1;
      v_ignoradas := v_ignoradas || jsonb_build_array(
        jsonb_build_object('nome', v_nome, 'gasto', v_gasto));
      continue;
    end if;

    v_lanc := dash.lancamento_na_data(v_data::timestamptz);
    if v_lanc is null then
      v_sem_data := v_sem_data + 1;
      continue;
    end if;

    -- uma entidade por campanha e dia, para o gasto poder ser atualizado
    -- sem duplicar quando a sincronização roda de novo
    v_chave := 'auto-' || coalesce(nullif(v_item->>'id',''), md5(v_nome));

    insert into dash.ads_entidades (id, lancamento_id, nivel, nome, conta_id)
    values (v_chave, v_lanc, 'ad', v_nome,
            coalesce(nullif(v_item->>'conta',''), 'meta'))
    on conflict (id) do update set
      nome = excluded.nome, lancamento_id = excluded.lancamento_id;

    insert into dash.ads_insights
      (ad_id, lancamento_id, data_ref, gasto, impressoes, cliques)
    values (
      v_chave, v_lanc, coalesce(nullif(v_item->>'dia','')::date, v_data), v_gasto,
      coalesce(nullif(v_item->>'impressoes','')::bigint, 0),
      coalesce(nullif(v_item->>'cliques','')::bigint, 0)
    )
    on conflict (ad_id, data_ref) do update set
      gasto = excluded.gasto,
      impressoes = excluded.impressoes,
      cliques = excluded.cliques,
      lancamento_id = excluded.lancamento_id;

    select slug into v_slug from dash.lancamentos where id = v_lanc;
    v_por_lanc := jsonb_set(v_por_lanc, array[v_slug],
      to_jsonb(round(coalesce((v_por_lanc->>v_slug)::numeric, 0) + v_gasto, 2)));

    v_qtd := v_qtd + 1;
    v_total := v_total + v_gasto;
  end loop;

  return jsonb_build_object(
    'ok', true, 'campanhas', v_qtd, 'gasto', round(v_total, 2),
    'fora_de_captacao', v_fora, 'sem_data_no_nome', v_sem_data,
    'ignoradas', v_ignoradas, 'por_lancamento', v_por_lanc
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. JANELA A BUSCAR
--    Do primeiro lançamento sem investimento até hoje, limitado a
--    13 meses — o máximo que a API do Meta devolve.
-- ---------------------------------------------------------------------
create or replace function public.periodo_investimento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_de date; v_ate date;
begin
  if nullif(p->>'de','') is not null then
    v_de := (p->>'de')::date;
    v_ate := coalesce(nullif(p->>'ate','')::date, current_date);
  else
    -- o começo do lançamento mais antigo que tem lead
    select min(capturado_em)::date into v_de from dash.inscricoes;
    v_de := coalesce(v_de, current_date - 90);
    v_ate := current_date;
  end if;

  if v_ate - v_de > 400 then v_de := v_ate - 400; end if;

  return jsonb_build_object(
    'ok', true, 'de', v_de, 'ate', v_ate,
    'contas', (
      select coalesce(jsonb_agg(distinct c), '[]'::jsonb)
      from dash.lancamentos l,
           jsonb_array_elements_text(
             case when jsonb_typeof(l.config->'meta_contas') = 'array'
                  then l.config->'meta_contas' else '[]'::jsonb end) c
    )
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. O QUE FICOU SEM INVESTIMENTO
--    Para a tela avisar antes de você olhar um ROAS incompleto.
-- ---------------------------------------------------------------------
create or replace function public.lancamentos_sem_investimento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'lancamento', nome, 'slug', slug, 'leads', leads, 'receita', receita
  ) order by inicio desc)
  into v_res
  from (
    select l.nome, l.slug, coalesce(l.captacao_inicio, l.criado_em) as inicio,
      (select count(*) from dash.inscricoes i where i.lancamento_id = l.id) as leads,
      (select coalesce(round(sum(v.valor_bruto),2),0) from dash.vendas v
       where v.lancamento_id = l.id and v.status = 'aprovada') as receita
    from dash.lancamentos l
    where not exists (select 1 from dash.ads_insights a where a.lancamento_id = l.id)
      and exists (select 1 from dash.inscricoes i where i.lancamento_id = l.id)
  ) t;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.ingest_investimento(jsonb), public.periodo_investimento(jsonb),
  public.lancamentos_sem_investimento(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_investimento(jsonb), public.periodo_investimento(jsonb),
  public.lancamentos_sem_investimento(jsonb) to service_role;

select 'pronto' as status;
