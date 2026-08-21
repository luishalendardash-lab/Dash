-- =====================================================================
-- 43 — IMPORTAR O CONSOLIDADO PELO SUPABASE
--
-- Sem passar pela dash: você sobe o CSV direto numa tabela de
-- recebimento, pela interface do Supabase, e roda o processamento.
--
-- COMO FAZER
--
--   1. Rode este arquivo inteiro (cria a tabela e a função)
--   2. Table Editor > public > import_leads > Insert > Import data from CSV
--      escolha leads-consolidado.csv
--   3. Rode:  select public.processar_import();
--      Ele processa 1.500 linhas por vez e diz quantas faltam.
--      Repita o mesmo comando até 'faltam' chegar a zero (9 vezes).
--   4. Confira: select jsonb_pretty(public.diagnostico_leads('{}'::jsonb));
--   5. Rode:  drop table public.import_leads;
--
-- Por que em lotes: o Supabase derruba consulta que passa de alguns
-- segundos. Cada linha faz várias buscas e escritas, então 12 mil de uma
-- vez estoura. A coluna 'processado' guarda onde parou.
--
-- A tabela é toda de texto de propósito: qualquer conversão feita na
-- importação do CSV poderia falhar em silêncio e trocar uma data. Aqui
-- a conversão acontece no processamento, onde dá para tratar o erro.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. TABELA DE RECEBIMENTO
--    Fica em public porque é lá que o importador do Supabase escreve.
-- ---------------------------------------------------------------------
drop table if exists public.import_leads;

create table public.import_leads (
  -- id e processado permitem rodar em lotes: o Supabase derruba
  -- consulta longa, e 12 mil linhas de uma vez passa do limite
  id           bigserial primary key,
  processado   boolean not null default false,
  lancamento   text,
  nome         text,
  email        text,
  telefone     text,
  data         text,
  campanha     text,
  conjunto     text,
  anuncio      text,
  anuncio_id   text,
  conjunto_id  text,
  campanha_id  text,
  formacao     text,
  engenheiro   text,
  fez_quiz     text,
  sck          text,
  respostas    text
);

create index if not exists ix_import_pendente on public.import_leads (processado)
  where not processado;

-- o importador do Supabase precisa poder escrever
grant all on public.import_leads to service_role, authenticated, anon;

-- ---------------------------------------------------------------------
-- 2. PROCESSAR
--    Lê a tabela de recebimento e grava nas tabelas da dash.
--    Rodar duas vezes não duplica: completa em vez de inserir.
-- ---------------------------------------------------------------------
-- remove a versao anterior: com o parametro novo elas coexistiriam e o
-- Postgres nao saberia qual chamar
drop function if exists public.processar_import();

create or replace function public.processar_import(p_lote int default 1500)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  r record; v_lanc uuid; v_restam int; v_email text; v_fone text; v_data timestamptz;
  v_pessoa uuid; v_insc uuid; v_eng boolean; v_tem_form boolean;
  v_chave text; v_valor text; v_resp jsonb;
  v_novos int := 0; v_completados int := 0; v_erros int := 0;
  v_respostas int := 0; v_sem_lanc int := 0;
  v_primeiro_erro text; v_por_lanc jsonb := '{}'::jsonb;
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema = 'public' and table_name = 'import_leads') then
    return jsonb_build_object('ok', false,
      'erro', 'a tabela public.import_leads nao existe. Rode o arquivo 43 primeiro.');
  end if;

  -- só o que ainda não foi processado, em lotes que cabem no tempo limite
  for r in select * from public.import_leads
           where not processado order by id limit p_lote
  loop
    begin
      select id into v_lanc from dash.lancamentos
      where slug = nullif(btrim(r.lancamento), '');

      if v_lanc is null then
        v_sem_lanc := v_sem_lanc + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'lancamento nao encontrado: ' || coalesce(r.lancamento, '(vazio)'));
        continue;
      end if;

      v_email := dash.norm_email(r.email);
      v_fone  := dash.norm_phone(r.telefone);
      if v_email is null and v_fone is null then
        v_erros := v_erros + 1;
        continue;
      end if;

      v_data := dash.texto_para_data(r.data);
      v_tem_form := nullif(btrim(coalesce(r.formacao, '')), '') is not null;
      v_eng := lower(btrim(coalesce(r.engenheiro, ''))) in ('sim', 'true', '1');

      -- pessoa: e-mail primeiro, telefone como reserva
      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      if v_pessoa is null then
        insert into dash.pessoas (nome, email, telefone, criado_em)
        values (nullif(btrim(r.nome), ''), v_email, v_fone, coalesce(v_data, now()))
        returning id into v_pessoa;
      else
        update dash.pessoas set
          nome = coalesce(nome, nullif(btrim(r.nome), '')),
          email = coalesce(email, v_email),
          telefone = coalesce(telefone, v_fone)
        where id = v_pessoa;
      end if;

      select id into v_insc from dash.inscricoes
      where pessoa_id = v_pessoa and lancamento_id = v_lanc;

      if v_insc is null then
        insert into dash.inscricoes (
          lancamento_id, pessoa_id, capturado_em, data_aproximada,
          utm_source, utm_medium, utm_campaign, utm_content,
          meta_campaign_id, meta_adset_id, meta_ad_id,
          origem_sistema, engenheiro, fez_quiz, comprou
        ) values (
          v_lanc, v_pessoa, coalesce(v_data, now()), v_data is null,
          nullif(btrim(r.campanha), ''),
          nullif(btrim(r.conjunto), ''),
          nullif(btrim(r.campanha), ''),
          nullif(btrim(r.anuncio), ''),
          nullif(btrim(r.campanha_id), ''),
          nullif(btrim(r.conjunto_id), ''),
          nullif(btrim(r.anuncio_id), ''),
          'importacao', v_eng,
          lower(coalesce(r.fez_quiz, '')) = 'sim',
          false
        )
        returning id into v_insc;
        v_novos := v_novos + 1;

        insert into dash.eventos
          (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key)
        values (v_insc, v_pessoa, v_lanc, 'captura', 'importacao',
                coalesce(v_data, now()), 'importado:' || v_insc::text)
        on conflict (dedupe_key) do nothing;
      else
        -- completa o que falta, sem apagar o que já está certo
        update dash.inscricoes set
          utm_source   = coalesce(utm_source,   nullif(btrim(r.campanha), '')),
          utm_medium   = coalesce(utm_medium,   nullif(btrim(r.conjunto), '')),
          utm_campaign = coalesce(utm_campaign, nullif(btrim(r.campanha), '')),
          utm_content  = coalesce(utm_content,  nullif(btrim(r.anuncio), '')),
          meta_campaign_id = coalesce(meta_campaign_id, nullif(btrim(r.campanha_id), '')),
          meta_adset_id = coalesce(meta_adset_id, nullif(btrim(r.conjunto_id), '')),
          meta_ad_id   = coalesce(meta_ad_id,   nullif(btrim(r.anuncio_id), '')),
          engenheiro   = case when v_tem_form then v_eng else engenheiro end,
          fez_quiz     = fez_quiz or lower(coalesce(r.fez_quiz, '')) = 'sim',
          capturado_em = case when data_aproximada and v_data is not null
                              then v_data else capturado_em end,
          data_aproximada = case when data_aproximada and v_data is not null
                                 then false else data_aproximada end,
          atualizado_em = now()
        where id = v_insc;
        v_completados := v_completados + 1;
      end if;

      -- respostas do quiz, guardadas como JSON numa coluna só
      if nullif(btrim(coalesce(r.respostas, '')), '') is not null then
        begin
          v_resp := r.respostas::jsonb;
          for v_chave, v_valor in select key, value from jsonb_each_text(v_resp)
          loop
            continue when btrim(coalesce(v_valor, '')) = '';
            insert into dash.quiz_respostas_livres (inscricao_id, pergunta, resposta)
            values (v_insc, v_chave, btrim(v_valor))
            on conflict (inscricao_id, pergunta) do update set resposta = excluded.resposta;
            v_respostas := v_respostas + 1;
          end loop;
        exception when others then
          null;   -- respostas ilegíveis não derrubam o lead
        end;
      end if;

      v_por_lanc := jsonb_set(v_por_lanc, array[r.lancamento],
        to_jsonb(coalesce((v_por_lanc->>r.lancamento)::int, 0) + 1));

      update public.import_leads set processado = true where id = r.id;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
      -- marca mesmo com erro: senão o lote seguinte tenta a mesma linha
      update public.import_leads set processado = true where id = r.id;
    end;
  end loop;

  select count(*) into v_restam from public.import_leads where not processado;

  return jsonb_build_object(
    'ok', true,
    'novos', v_novos, 'completados', v_completados,
    'respostas', v_respostas, 'sem_lancamento', v_sem_lanc,
    'erros', v_erros, 'primeiro_erro', v_primeiro_erro,
    'por_lancamento', v_por_lanc,
    'faltam', v_restam,
    'proximo_passo', case when v_restam > 0
      then 'rode select public.processar_import(); de novo — faltam '
           || v_restam || ' linhas'
      else 'terminou' end
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. LIMPAR TODOS OS LANÇAMENTOS DE UMA VEZ
--    Para começar do zero antes de importar o consolidado.
-- ---------------------------------------------------------------------
create or replace function public.limpar_todo_historico(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_qtd int; v_pessoas int;
begin
  if coalesce(p->>'confirmar','') <> 'LIMPAR TUDO' then
    return jsonb_build_object('ok', false, 'erro', 'envie confirmar: LIMPAR TUDO');
  end if;

  -- vendas perdem o vínculo mas continuam existindo
  update dash.vendas v set inscricao_id = null
  where v.inscricao_id in (
    select id from dash.inscricoes where origem_sistema = 'importacao');

  with alvo as (select id from dash.inscricoes where origem_sistema = 'importacao'),
  a as (delete from dash.quiz_respostas_livres where inscricao_id in (select id from alvo)),
  b as (delete from dash.quiz_respostas where inscricao_id in (select id from alvo)),
  c as (delete from dash.eventos where inscricao_id in (select id from alvo)),
  d as (delete from dash.inscricoes where id in (select id from alvo) returning 1)
  select count(*) into v_qtd from d;

  with p2 as (
    delete from dash.pessoas p3
    where not exists (select 1 from dash.inscricoes i where i.pessoa_id = p3.id)
      and not exists (select 1 from dash.vendas v where v.pessoa_id = p3.id)
    returning 1
  )
  select count(*) into v_pessoas from p2;

  return jsonb_build_object('ok', true, 'leads_apagados', v_qtd,
                            'pessoas_apagadas', v_pessoas);
end $$;

-- ---------------------------------------------------------------------
-- 4. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.processar_import(int), public.limpar_todo_historico(jsonb)
  from anon;
grant execute on function public.processar_import(int), public.limpar_todo_historico(jsonb)
  to service_role, authenticated;

select 'tabela public.import_leads criada. Suba o CSV por Table Editor > Import data from CSV'
  as proximo_passo;
