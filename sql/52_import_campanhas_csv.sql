-- =====================================================================
-- 52 — INVESTIMENTO PELO CSV DE CAMPANHAS
--
-- O export de campanhas do Meta traz nome, período e gasto de tudo que
-- rodou. E os nomes seguem um padrão com a data — [10.01.26][CAPTAÇÃO]
-- — que diz a qual lançamento cada campanha pertence, sem depender de
-- sigla nem de renomear nada no Meta.
--
-- COMO FAZER
--   1. Rode este arquivo
--   2. Table Editor > public > import_campanhas > Import data from CSV
--   3. select public.processar_campanhas();
--   4. Confira e ajuste o que ficou fora
--   5. drop table public.import_campanhas;
-- =====================================================================

set search_path = dash, public;

drop table if exists public.import_campanhas;

create table public.import_campanhas (
  id          bigserial primary key,
  processado  boolean not null default false,
  nome        text,
  inicio      text,
  fim         text,
  gasto       text,
  impressoes  text,
  cliques     text,
  resultados  text
);

grant all on public.import_campanhas to service_role, authenticated, anon;
grant usage, select on sequence public.import_campanhas_id_seq
  to service_role, authenticated, anon;

-- ---------------------------------------------------------------------
-- A DATA ESCONDIDA NO NOME
--   [10.01.26][CAPTAÇÃO][ABO]  ->  2026-01-10
-- ---------------------------------------------------------------------
create or replace function dash.data_do_nome(p_nome text)
returns date language plpgsql immutable as $$
declare m text[];
begin
  m := regexp_match(coalesce(p_nome, ''), '\[(\d{2})\.(\d{2})\.(\d{2})\]');
  if m is null then return null; end if;
  return make_date(2000 + m[3]::int, m[2]::int, m[1]::int);
exception when others then
  return null;
end $$;

-- ---------------------------------------------------------------------
-- PROCESSAR
--   Cada campanha vai para o lançamento em cuja janela a data do nome
--   cai. Sem data no nome, usa a data de início do relatório.
--   p: { so_captacao: true }  ignora campanhas de vendas e remarketing
-- ---------------------------------------------------------------------
create or replace function public.processar_campanhas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  r record; v_data date; v_lanc uuid; v_slug text; v_chave text;
  v_so_cap boolean; v_gasto numeric;
  v_qtd int := 0; v_ignoradas int := 0; v_sem_lanc int := 0; v_erros int := 0;
  v_total numeric := 0; v_por_lanc jsonb := '{}'::jsonb; v_primeiro_erro text;
begin
  v_so_cap := coalesce((p->>'so_captacao')::boolean, false);

  for r in select * from public.import_campanhas where not processado order by id
  loop
    begin
      v_gasto := dash.valor_para_numero(r.gasto);
      if coalesce(v_gasto, 0) <= 0 then
        v_ignoradas := v_ignoradas + 1;
        update public.import_campanhas set processado = true where id = r.id;
        continue;
      end if;

      -- só captação, quando pedido: campanha de vendas e remarketing
      -- gasta no mesmo período mas não traz lead novo
      if v_so_cap and upper(translate(coalesce(r.nome,''),
           'ÇÃÁÉÍÓÚÂÊÔÕ', 'CAAEIOUAEOO')) not like '%CAPTACAO%' then
        v_ignoradas := v_ignoradas + 1;
        update public.import_campanhas set processado = true where id = r.id;
        continue;
      end if;

      -- a data do nome vence a do relatório: o relatório é o período do
      -- export, não o da campanha
      v_data := coalesce(dash.data_do_nome(r.nome),
                         dash.texto_para_data(r.inicio)::date);
      if v_data is null then
        v_sem_lanc := v_sem_lanc + 1;
        update public.import_campanhas set processado = true where id = r.id;
        continue;
      end if;

      v_lanc := dash.lancamento_na_data(v_data::timestamptz);
      if v_lanc is null then
        v_sem_lanc := v_sem_lanc + 1;
        update public.import_campanhas set processado = true where id = r.id;
        continue;
      end if;

      -- uma entidade por campanha; o insight cai na data do nome
      v_chave := 'csv-' || md5(coalesce(r.nome, '') || v_data::text);

      insert into dash.ads_entidades (id, lancamento_id, nivel, nome, conta_id)
      values (v_chave, v_lanc, 'ad', coalesce(nullif(btrim(r.nome),''), v_chave), 'csv')
      on conflict (id) do update set
        nome = excluded.nome, lancamento_id = excluded.lancamento_id;

      insert into dash.ads_insights
        (ad_id, lancamento_id, data_ref, gasto, impressoes, cliques)
      values (
        v_chave, v_lanc, v_data, v_gasto,
        coalesce(nullif(regexp_replace(coalesce(r.impressoes,''), '\D', '', 'g'),'')::bigint, 0),
        coalesce(nullif(regexp_replace(coalesce(r.cliques,''), '\D', '', 'g'),'')::bigint, 0)
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
      update public.import_campanhas set processado = true where id = r.id;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
      update public.import_campanhas set processado = true where id = r.id;
    end;
  end loop;

  return jsonb_build_object(
    'ok', true, 'campanhas', v_qtd,
    'gasto_total', round(v_total, 2),
    'ignoradas', v_ignoradas, 'sem_lancamento', v_sem_lanc,
    'erros', v_erros, 'primeiro_erro', v_primeiro_erro,
    'por_lancamento', v_por_lanc
  );
end $$;

-- ---------------------------------------------------------------------
-- APAGAR O QUE VEIO DO CSV
--   Para reimportar com outro critério, sem perder o que veio da API.
-- ---------------------------------------------------------------------
create or replace function public.limpar_investimento_csv(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_qtd int;
begin
  with a as (
    delete from dash.ads_insights
    where ad_id like 'csv-%' or ad_id like 'geral-%'
    returning 1
  )
  select count(*) into v_qtd from a;

  delete from dash.ads_entidades where id like 'csv-%' or id like 'geral-%';

  return jsonb_build_object('ok', true, 'apagados', v_qtd);
end $$;

revoke all on function public.processar_campanhas(jsonb),
  public.limpar_investimento_csv(jsonb) from anon;
grant execute on function public.processar_campanhas(jsonb),
  public.limpar_investimento_csv(jsonb) to service_role, authenticated;

select 'tabela public.import_campanhas criada' as proximo_passo;
