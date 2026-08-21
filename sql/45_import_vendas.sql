-- =====================================================================
-- 45 — IMPORTAR AS VENDAS PELO SUPABASE
--
-- Mesmo caminho do consolidado de leads: sobe o CSV numa tabela de
-- recebimento e processa.
--
-- O lançamento não vem no arquivo: cada venda cai no lançamento que
-- estava vigente na data da compra. Isso é mais confiável do que decidir
-- na planilha, e funciona para venda que aconteceu fora de campanha.
--
-- COMO FAZER
--   1. Rode este arquivo
--   2. Table Editor > public > import_vendas > Import data from CSV
--      escolha vendas-hotmart.csv
--   3. Rode:  select public.processar_vendas();
--      Repita até 'faltam' chegar a zero
--   4. Confira na aba Vendas da dash
--   5. Rode:  drop table public.import_vendas;
-- =====================================================================

set search_path = dash, public;

drop table if exists public.import_vendas;

create table public.import_vendas (
  id            bigserial primary key,
  processado    boolean not null default false,
  transacao     text,
  data          text,
  email         text,
  telefone      text,
  nome          text,
  produto       text,
  oferta        text,
  plataforma    text,
  status        text,
  valor         text,
  valor_liquido text,
  metodo        text,
  parcelas      text,
  sck           text
);

create index if not exists ix_import_vendas_pend on public.import_vendas (processado)
  where not processado;

grant all on public.import_vendas to service_role, authenticated, anon;
grant usage, select on sequence public.import_vendas_id_seq
  to service_role, authenticated, anon;

create or replace function public.processar_vendas(p_lote int default 2000)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  r record; v_lanc uuid; v_email text; v_fone text; v_data timestamptz;
  v_valor numeric; v_pessoa uuid; v_insc uuid; v_restam int;
  v_novas int := 0; v_repetidas int := 0; v_erros int := 0;
  v_ligadas int := 0; v_sem_lanc int := 0; v_primeiro_erro text;
  v_por_lanc jsonb := '{}'::jsonb; v_slug text;
begin
  for r in select * from public.import_vendas
           where not processado order by id limit p_lote
  loop
    begin
      v_data := dash.texto_para_data(r.data);
      if v_data is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'data invalida: ' || coalesce(r.data, '(vazia)'));
        update public.import_vendas set processado = true where id = r.id;
        continue;
      end if;

      v_valor := dash.valor_para_numero(r.valor);
      if v_valor is null then
        v_erros := v_erros + 1;
        update public.import_vendas set processado = true where id = r.id;
        continue;
      end if;

      -- a venda cai no lançamento vigente na data da compra
      v_lanc := dash.lancamento_na_data(v_data);
      if v_lanc is null then v_sem_lanc := v_sem_lanc + 1; end if;

      if exists (select 1 from dash.vendas
                 where transacao_id = r.transacao
                   and plataforma = coalesce(nullif(r.plataforma,''), 'importacao')) then
        v_repetidas := v_repetidas + 1;
        update public.import_vendas set processado = true where id = r.id;
        continue;
      end if;

      v_email := dash.norm_email(r.email);
      v_fone  := dash.norm_phone(r.telefone);

      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      -- comprador que não existe como lead entra como pessoa: é dele o
      -- faturamento, e amanhã ele pode virar lead de outro lançamento
      if v_pessoa is null and (v_email is not null or v_fone is not null) then
        insert into dash.pessoas (nome, email, telefone, criado_em)
        values (nullif(btrim(r.nome),''), v_email, v_fone, v_data)
        returning id into v_pessoa;
      end if;

      v_insc := null;
      if v_pessoa is not null and v_lanc is not null then
        select id into v_insc from dash.inscricoes
        where pessoa_id = v_pessoa and lancamento_id = v_lanc limit 1;

        -- comprou sem passar pela captação daquele lançamento: liga na
        -- participação anterior mais recente
        if v_insc is null then
          select i.id into v_insc
          from dash.inscricoes i
          join dash.lancamentos l on l.id = i.lancamento_id
          where i.pessoa_id = v_pessoa
            and coalesce(l.captacao_inicio, l.criado_em) <= v_data
          order by coalesce(l.captacao_inicio, l.criado_em) desc
          limit 1;
        end if;
      end if;

      insert into dash.vendas (
        lancamento_id, pessoa_id, inscricao_id, plataforma, transacao_id,
        produto, oferta, status, metodo, parcelas,
        valor_bruto, valor_liquido, moeda,
        email_comprador, fone_comprador, src_hotmart, ocorreu_em, raw
      ) values (
        v_lanc, v_pessoa, v_insc,
        coalesce(nullif(btrim(r.plataforma),''), 'importacao'),
        r.transacao,
        nullif(btrim(r.produto),''),
        nullif(btrim(r.oferta),''),
        coalesce(nullif(btrim(lower(r.status)),''), 'aprovada'),
        nullif(btrim(r.metodo),''),
        -- a coluna e inteira; texto vazio ou nao numerico vira nulo
        (select case when btrim(coalesce(r.parcelas,'')) ~ '^[0-9]+$'
                     then btrim(r.parcelas)::int end),
        v_valor,
        coalesce(dash.valor_para_numero(r.valor_liquido), 0),
        'BRL',
        r.email, r.telefone,
        nullif(btrim(r.sck),''),
        v_data,
        to_jsonb(r)
      );

      if v_insc is not null and lower(coalesce(r.status,'')) = 'aprovada' then
        v_ligadas := v_ligadas + 1;
        update dash.inscricoes set
          comprou = true,
          comprou_em = coalesce(comprou_em, v_data),
          etapa = 'comprou'
        where id = v_insc;
      end if;

      if v_lanc is not null then
        select slug into v_slug from dash.lancamentos where id = v_lanc;
        v_por_lanc := jsonb_set(v_por_lanc, array[v_slug],
          to_jsonb(coalesce((v_por_lanc->>v_slug)::int, 0) + 1));
      end if;

      v_novas := v_novas + 1;
      update public.import_vendas set processado = true where id = r.id;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
      update public.import_vendas set processado = true where id = r.id;
    end;
  end loop;

  select count(*) into v_restam from public.import_vendas where not processado;

  return jsonb_build_object(
    'ok', true, 'novas', v_novas, 'ligadas_a_lead', v_ligadas,
    'repetidas', v_repetidas, 'sem_lancamento', v_sem_lanc,
    'erros', v_erros, 'primeiro_erro', v_primeiro_erro,
    'por_lancamento', v_por_lanc, 'faltam', v_restam,
    'proximo_passo', case when v_restam > 0
      then 'rode de novo — faltam ' || v_restam else 'terminou' end
  );
end $$;

revoke all on function public.processar_vendas(int) from anon;
grant execute on function public.processar_vendas(int) to service_role, authenticated;

select 'tabela public.import_vendas criada. Suba vendas-hotmart.csv por Table Editor'
  as proximo_passo;
