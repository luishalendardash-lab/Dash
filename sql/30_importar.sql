-- =====================================================================
-- 30 — IMPORTAR HISTÓRICO
--
-- Traz leads e vendas de lançamentos anteriores, exportados do SellFlux
-- ou da plataforma de venda.
--
-- Dois cuidados que definem o resultado:
--
--   1. A data de cada linha manda. Sem ela, tudo entraria com a data de
--      hoje e o gráfico de captação viraria uma barra só. O importador
--      recusa a linha se a data vier inválida.
--
--   2. Importar duas vezes não pode duplicar. A dedupe usa e-mail +
--      lançamento para leads, e o id da transação para vendas.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. OS SEIS LANÇAMENTOS ANTERIORES
--    Bimestrais, mesmo produto. Status encerrado: não recebem webhook.
-- ---------------------------------------------------------------------
insert into dash.lancamentos
  (slug, nome, produto, status, codigo, captacao_inicio, criado_em)
values
  ('fpee-2025-09', 'FPEE Set/25', 'FPEE - Formação Perito em Engenharia Elétrica',
   'encerrado', 'L2509', '2025-09-01', '2025-09-01'),
  ('fpee-2025-11', 'FPEE Nov/25', 'FPEE - Formação Perito em Engenharia Elétrica',
   'encerrado', 'L2511', '2025-11-01', '2025-11-01'),
  ('fpee-2026-01', 'FPEE Jan/26', 'FPEE - Formação Perito em Engenharia Elétrica',
   'encerrado', 'L2601', '2026-01-01', '2026-01-01'),
  ('fpee-2026-03', 'FPEE Mar/26', 'FPEE - Formação Perito em Engenharia Elétrica',
   'encerrado', 'L2603', '2026-03-01', '2026-03-01'),
  ('fpee-2026-05', 'FPEE Mai/26', 'FPEE - Formação Perito em Engenharia Elétrica',
   'encerrado', 'L2605', '2026-05-01', '2026-05-01'),
  ('fpee-2026-07', 'FPEE Jul/26', 'FPEE - Formação Perito em Engenharia Elétrica',
   'encerrado', 'L2607', '2026-07-01', '2026-07-01')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- LER DATA EM QUALQUER FORMATO
--
-- O Postgres, no padrão americano, lê "11/07/2026" como 7 de novembro.
-- Numa importação inteira isso espalha os leads nos meses errados e o
-- gráfico de captação fica sem sentido. Por isso a leitura é explícita:
-- com barra, assumimos dia/mês/ano, que é o que sai do SellFlux.
-- ---------------------------------------------------------------------
create or replace function dash.texto_para_data(txt text)
returns timestamptz language plpgsql immutable as $$
declare v text; v_d timestamptz;
begin
  v := btrim(coalesce(txt, ''));
  if v = '' then return null; end if;

  -- dd/mm/aaaa ou dd/mm/aaaa hh:mm(:ss)
  if v ~ '^\d{1,2}/\d{1,2}/\d{4}' then
    begin
      v_d := to_timestamp(v, 'DD/MM/YYYY HH24:MI:SS');
      return v_d;
    exception when others then
      begin
        return to_timestamp(split_part(v, ' ', 1), 'DD/MM/YYYY');
      exception when others then return null; end;
    end;
  end if;

  -- aaaa-mm-dd e ISO em geral
  begin
    return v::timestamptz;
  exception when others then
    return null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 2. IMPORTAR LEADS
--    p: { lancamento, linhas: [ {nome,email,telefone,data,utm_*,...}, ... ] }
-- ---------------------------------------------------------------------
create or replace function public.importar_leads(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_linha jsonb;
  v_email text; v_fone text; v_data timestamptz;
  v_pessoa uuid; v_insc uuid;
  v_novos int := 0; v_repetidos int := 0; v_erros int := 0;
  v_primeiro_erro text;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  for v_linha in select * from jsonb_array_elements(
    case when jsonb_typeof(p->'linhas') = 'array' then p->'linhas' else '[]'::jsonb end
  )
  loop
    begin
      v_email := dash.norm_email(v_linha->>'email');
      v_fone := dash.norm_phone(v_linha->>'telefone');

      -- sem e-mail nem telefone não há como identificar a pessoa
      if v_email is null and v_fone is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro, 'linha sem email e sem telefone');
        continue;
      end if;

      -- a data é o que faz o histórico valer: sem ela, o dado mente
      v_data := dash.texto_para_data(v_linha->>'data');
      if v_data is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'data invalida: ' || coalesce(v_linha->>'data','(vazia)'));
        continue;
      end if;

      -- Procura a pessoa: primeiro pelo e-mail, que é mais confiável.
      -- Casar por telefone antes causaria fusão errada quando dois leads
      -- compartilham telefone (casal, empresa).
      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      if v_pessoa is null then
        insert into dash.pessoas (nome, email, telefone, criado_em)
        values (nullif(btrim(v_linha->>'nome'),''), v_email, v_fone, v_data)
        returning id into v_pessoa;
      else
        update dash.pessoas set
          nome = coalesce(nome, nullif(btrim(v_linha->>'nome'),'')),
          email = coalesce(email, v_email),
          telefone = coalesce(telefone, v_fone)
        where id = v_pessoa;
      end if;

      -- inscrição
      select id into v_insc from dash.inscricoes
      where pessoa_id = v_pessoa and lancamento_id = v_lanc;

      if v_insc is not null then
        v_repetidos := v_repetidos + 1;
        continue;
      end if;

      insert into dash.inscricoes (
        pessoa_id, lancamento_id, capturado_em,
        utm_source, utm_medium, utm_campaign, utm_content, utm_term,
        meta_ad_id, origem_sistema, comprou
      ) values (
        v_pessoa, v_lanc, v_data,
        nullif(btrim(v_linha->>'utm_source'),''),
        nullif(btrim(v_linha->>'utm_medium'),''),
        nullif(btrim(v_linha->>'utm_campaign'),''),
        nullif(btrim(v_linha->>'utm_content'),''),
        nullif(btrim(v_linha->>'utm_term'),''),
        nullif(btrim(v_linha->>'ad_id'),''),
        'importacao',
        false
      )
      returning id into v_insc;

      insert into dash.eventos
        (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key, payload)
      values (v_insc, v_pessoa, v_lanc, 'captura', 'importacao', v_data,
              'importado:' || v_insc::text, '{}'::jsonb)
      on conflict do nothing;

      v_novos := v_novos + 1;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true, 'novos', v_novos, 'repetidos', v_repetidos,
    'erros', v_erros, 'primeiro_erro', v_primeiro_erro
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. IMPORTAR VENDAS
--    Cruza com o lead pelo e-mail ou telefone, como faz o webhook.
-- ---------------------------------------------------------------------
create or replace function public.importar_vendas(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_linha jsonb;
  v_email text; v_fone text; v_data timestamptz; v_valor numeric;
  v_pessoa uuid; v_insc uuid; v_transacao text;
  v_novas int := 0; v_repetidas int := 0; v_erros int := 0;
  v_ligadas int := 0; v_primeiro_erro text;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  for v_linha in select * from jsonb_array_elements(
    case when jsonb_typeof(p->'linhas') = 'array' then p->'linhas' else '[]'::jsonb end
  )
  loop
    begin
      v_email := dash.norm_email(v_linha->>'email');
      v_fone := dash.norm_phone(v_linha->>'telefone');

      v_data := dash.texto_para_data(v_linha->>'data');
      if v_data is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'data invalida: ' || coalesce(v_linha->>'data','(vazia)'));
        continue;
      end if;

      -- aceita "1.997,00" e "1997.00"
      v_valor := dash.valor_para_numero(v_linha->>'valor');
      if v_valor is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'valor invalido: ' || coalesce(v_linha->>'valor','(vazio)'));
        continue;
      end if;

      v_transacao := coalesce(
        nullif(btrim(v_linha->>'transacao'),''),
        'imp-' || md5(coalesce(v_email,'') || coalesce(v_data::text,'') || v_valor::text)
      );

      if exists (select 1 from dash.vendas
                 where transacao_id = v_transacao
                   and plataforma = coalesce(nullif(v_linha->>'plataforma',''),'importacao')) then
        v_repetidas := v_repetidas + 1;
        continue;
      end if;

      -- procura a pessoa; a venda entra mesmo sem achar
      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      if v_pessoa is not null then
        select id into v_insc from dash.inscricoes
        where pessoa_id = v_pessoa and lancamento_id = v_lanc limit 1;
      else
        v_insc := null;
      end if;

      insert into dash.vendas (
        lancamento_id, pessoa_id, inscricao_id, plataforma, transacao_id,
        produto, oferta, status, metodo, valor_bruto, valor_liquido,
        moeda, email_comprador, fone_comprador, src_hotmart, ocorreu_em, raw
      ) values (
        v_lanc, v_pessoa, v_insc,
        coalesce(nullif(btrim(v_linha->>'plataforma'),''), 'importacao'),
        v_transacao,
        nullif(btrim(v_linha->>'produto'),''),
        nullif(btrim(v_linha->>'oferta'),''),
        coalesce(nullif(btrim(lower(v_linha->>'status')),''), 'aprovada'),
        nullif(btrim(v_linha->>'metodo'),''),
        v_valor,
        coalesce(dash.valor_para_numero(v_linha->>'valor_liquido'), 0),
        'BRL',
        v_linha->>'email',
        v_linha->>'telefone',
        nullif(btrim(v_linha->>'sck'),''),
        v_data,
        v_linha
      );

      if v_insc is not null then
        v_ligadas := v_ligadas + 1;
        update dash.inscricoes set
          comprou = true,
          comprou_em = coalesce(comprou_em, v_data),
          etapa = 'comprou'
        where id = v_insc;
      end if;

      v_novas := v_novas + 1;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true, 'novas', v_novas, 'ligadas_a_lead', v_ligadas,
    'repetidas', v_repetidas, 'erros', v_erros, 'primeiro_erro', v_primeiro_erro
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. LER VALOR EM QUALQUER FORMATO
--    "R$ 1.997,00" / "1997.00" / "1997" — tudo vira 1997.00
-- ---------------------------------------------------------------------
create or replace function dash.valor_para_numero(txt text)
returns numeric language plpgsql immutable as $$
declare v text; v_num numeric;
begin
  v := btrim(coalesce(txt, ''));
  if v = '' then return null; end if;

  v := regexp_replace(v, '[^0-9,.\-]', '', 'g');
  if v = '' then return null; end if;

  -- se tem vírgula e ponto, o último separador é o decimal
  if position(',' in v) > 0 and position('.' in v) > 0 then
    if position(',' in reverse(v)) < position('.' in reverse(v)) then
      v := replace(replace(v, '.', ''), ',', '.');   -- 1.997,00
    else
      v := replace(v, ',', '');                      -- 1,997.00
    end if;
  elsif position(',' in v) > 0 then
    -- só vírgula: decimal se sobram 1 ou 2 dígitos depois dela
    if length(split_part(v, ',', 2)) between 1 and 2 then
      v := replace(v, ',', '.');
    else
      v := replace(v, ',', '');
    end if;
  elsif position('.' in v) > 0 then
    -- só ponto com 3 dígitos depois: é milhar, não decimal.
    -- "1.997" é mil novecentos e noventa e sete, não um e noventa e sete.
    if length(split_part(v, '.', 2)) = 3 and position('.' in reverse(v)) = 4 then
      v := replace(v, '.', '');
    end if;
  end if;

  begin
    v_num := v::numeric;
  exception when others then
    return null;
  end;
  return v_num;
end $$;

-- ---------------------------------------------------------------------
-- 5. RESUMO DO QUE JÁ FOI IMPORTADO
-- ---------------------------------------------------------------------
create or replace function public.resumo_importacao(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'slug', l.slug, 'nome', l.nome, 'status', l.status,
    'leads', (select count(*) from dash.inscricoes i where i.lancamento_id = l.id),
    'com_utm', (select count(*) from dash.inscricoes i
                where i.lancamento_id = l.id and i.utm_campaign is not null),
    'vendas', (select count(*) from dash.vendas v
               where v.lancamento_id = l.id and v.status = 'aprovada'),
    'vendas_ligadas', (select count(*) from dash.vendas v
                       where v.lancamento_id = l.id and v.status = 'aprovada'
                         and v.inscricao_id is not null),
    'receita', (select coalesce(round(sum(v.valor_bruto),2),0) from dash.vendas v
                where v.lancamento_id = l.id and v.status = 'aprovada'),
    'primeiro_lead', (select min(i.capturado_em) from dash.inscricoes i
                      where i.lancamento_id = l.id),
    'ultimo_lead', (select max(i.capturado_em) from dash.inscricoes i
                    where i.lancamento_id = l.id)
  ) order by l.criado_em)
  into v_res from dash.lancamentos l;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 6. DESFAZER UMA IMPORTAÇÃO
-- ---------------------------------------------------------------------
create or replace function public.desfazer_importacao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_leads int; v_vendas int;
begin
  if coalesce(p->>'confirmar','') <> 'DESFAZER' then
    return jsonb_build_object('ok', false, 'erro', 'envie confirmar: DESFAZER');
  end if;

  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  -- só o que veio de importação; dado vindo de webhook fica
  select count(*) into v_vendas from dash.vendas
  where lancamento_id = v_lanc and plataforma = 'importacao';
  delete from dash.vendas where lancamento_id = v_lanc and plataforma = 'importacao';

  select count(*) into v_leads from dash.inscricoes
  where lancamento_id = v_lanc and origem_sistema = 'importacao';

  delete from dash.eventos where inscricao_id in (
    select id from dash.inscricoes
    where lancamento_id = v_lanc and origem_sistema = 'importacao');
  delete from dash.inscricoes where lancamento_id = v_lanc and origem_sistema = 'importacao';

  delete from dash.pessoas p2
  where not exists (select 1 from dash.inscricoes i where i.pessoa_id = p2.id)
    and not exists (select 1 from dash.vendas v where v.pessoa_id = p2.id);

  return jsonb_build_object('ok', true, 'leads', v_leads, 'vendas', v_vendas);
end $$;

-- ---------------------------------------------------------------------
-- 7. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.importar_leads(jsonb), public.importar_vendas(jsonb),
  public.resumo_importacao(jsonb), public.desfazer_importacao(jsonb)
  from public, anon, authenticated;
grant execute on function public.importar_leads(jsonb), public.importar_vendas(jsonb),
  public.resumo_importacao(jsonb), public.desfazer_importacao(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

select slug, nome, codigo from dash.lancamentos where slug like 'fpee-%' order by slug;
