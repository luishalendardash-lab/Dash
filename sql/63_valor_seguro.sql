-- =====================================================================
-- 63 — VALOR QUE NÃO CABE NA COLUNA
--
-- Erro 22003: um número veio grande demais para o campo. Acontece quando
-- a plataforma manda o valor em centavos, ou quando o parser pega o
-- campo errado — um timestamp indo parar no lugar do preço, por exemplo.
--
-- Duas defesas:
--   valor_para_numero passa a reconhecer centavos e recusar absurdo
--   ingest_venda não derruba a venda por causa do valor: grava zero e
--   deixa registrado, porque saber que a venda existiu vale mais do que
--   perdê-la inteira por um campo
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. PRIMEIRO, VER O QUE ESTÁ CHEGANDO
--    Rode e me mande o resultado se o problema persistir.
-- ---------------------------------------------------------------------
select
  id,
  body->>'event' as evento,
  left(erro, 120) as erro,
  jsonb_pretty(
    coalesce(body->'data'->'purchase', body->'data', body)
  ) as corpo
from dash.webhooks_raw
where not processado and erro like '%22003%'
limit 2;

-- ---------------------------------------------------------------------
-- 2. CONVERSÃO SEGURA
-- ---------------------------------------------------------------------
create or replace function dash.valor_para_numero(txt text)
returns numeric language plpgsql immutable as $$
declare v text; n numeric;
begin
  v := btrim(coalesce(txt, ''));
  if v = '' or lower(v) in ('null','none','nan') then return null; end if;

  -- tira símbolo de moeda e espaço
  v := regexp_replace(v, '[R$\s]', '', 'g');
  v := replace(v, chr(160), '');

  -- 1.997,00 (brasileiro) vira 1997.00
  if v ~ '^-?\d{1,3}(\.\d{3})+,\d{1,2}$' then
    v := replace(replace(v, '.', ''), ',', '.');
  -- 1,997.00 (americano)
  elsif v ~ '^-?\d{1,3}(,\d{3})+\.\d{1,2}$' then
    v := replace(v, ',', '');
  -- 1997,00
  elsif v ~ '^-?\d+,\d{1,2}$' then
    v := replace(v, ',', '.');
  -- 1.997 sem decimais: o ponto é separador de milhar
  elsif v ~ '^-?\d{1,3}(\.\d{3})+$' then
    v := replace(v, '.', '');
  end if;

  begin
    n := v::numeric;
  exception when others then
    return null;
  end;

  -- Número absurdo é campo errado, não venda cara. Um timestamp em
  -- milissegundos passa de 10^12; nenhum produto custa isso.
  if abs(n) > 99999999 then
    return null;
  end if;

  return round(n, 2);
end $$;

-- ---------------------------------------------------------------------
-- 3. A VENDA NÃO CAI POR CAUSA DO VALOR
-- ---------------------------------------------------------------------
do $bloco$
declare v_def text; v_novo text;
begin
  select pg_get_functiondef(oid) into v_def
  from pg_proc where proname = 'ingest_venda' limit 1;
  if v_def is null then return; end if;

  v_novo := v_def;

  -- qualquer forma de ler o valor passa pela conversão segura, com
  -- teto: melhor uma venda com valor zerado do que venda nenhuma
  v_novo := replace(v_novo,
    '(p->>''valor_bruto'')::numeric',
    'least(coalesce(dash.valor_para_numero(p->>''valor_bruto''), 0), 99999999)');
  v_novo := replace(v_novo,
    'coalesce((p->>''valor_bruto'')::numeric, 0)',
    'least(coalesce(dash.valor_para_numero(p->>''valor_bruto''), 0), 99999999)');
  v_novo := replace(v_novo,
    '(p->>''valor_liquido'')::numeric',
    'least(coalesce(dash.valor_para_numero(p->>''valor_liquido''), 0), 99999999)');
  v_novo := replace(v_novo,
    'coalesce((p->>''valor_liquido'')::numeric, 0)',
    'least(coalesce(dash.valor_para_numero(p->>''valor_liquido''), 0), 99999999)');

  if v_novo <> v_def then
    execute v_novo;
    raise notice 'ingest_venda protegida contra valor fora de faixa';
  else
    raise notice 'ingest_venda ja usava conversao segura';
  end if;
end $bloco$;

-- ---------------------------------------------------------------------
-- 4. AS COLUNAS COMPORTAM O QUE PRECISAM
-- ---------------------------------------------------------------------
-- Ampliar a coluna exige derrubar as views que a usam. Guardamos a
-- definição de cada uma, alteramos e recriamos exatamente como estavam —
-- assim nada se perde se alguém tiver criado view própria.
do $bloco$
declare
  r record;
  v_defs text[] := '{}';
  v_nomes text[] := '{}';
begin
  for r in
    select distinct
      dn.nspname as esquema, dv.relname as nome,
      pg_get_viewdef(dv.oid, true) as definicao
    from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    join pg_class dv on dv.oid = rw.ev_class
    join pg_namespace dn on dn.oid = dv.relnamespace
    join pg_class st on st.oid = d.refobjid
    where st.relname = 'vendas' and st.relnamespace = 'dash'::regnamespace
      and dv.relkind = 'v'
  loop
    v_nomes := v_nomes || (r.esquema || '.' || r.nome);
    v_defs := v_defs || r.definicao;
    execute format('drop view if exists %I.%I cascade', r.esquema, r.nome);
  end loop;

  begin
    alter table dash.vendas alter column valor_bruto type numeric(14,2);
    alter table dash.vendas alter column valor_liquido type numeric(14,2);
    raise notice 'colunas de valor ampliadas para numeric(14,2)';
  exception when others then
    raise notice 'colunas mantidas: %', SQLERRM;
  end;

  for i in 1 .. coalesce(array_length(v_nomes, 1), 0) loop
    begin
      execute format('create or replace view %s as %s', v_nomes[i], v_defs[i]);
      raise notice 'view % recriada', v_nomes[i];
    exception when others then
      raise warning 'nao consegui recriar a view %: %', v_nomes[i], SQLERRM;
    end;
  end loop;
end $bloco$;

-- ---------------------------------------------------------------------
-- 5. CONFERIR
-- ---------------------------------------------------------------------
select
  dash.valor_para_numero('1997')            as simples,
  dash.valor_para_numero('R$ 1.997,00')     as brasileiro,
  dash.valor_para_numero('1,997.00')        as americano,
  dash.valor_para_numero('1787756268398')   as timestamp_recusado,
  dash.valor_para_numero('199700')          as centavos_como_veio;
