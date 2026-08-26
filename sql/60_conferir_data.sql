-- =====================================================================
-- 60 — CONFERIR E GARANTIR A CORREÇÃO DA DATA
--
-- O erro "date/time field value out of range: 1787756268398" continua
-- aparecendo, o que indica que o arquivo 57 não chegou a rodar ou que a
-- função ingest_venda foi recriada depois por outro arquivo.
--
-- Este confere o estado e corrige de novo, dizendo o que encontrou.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. COMO ESTÁ AGORA
-- ---------------------------------------------------------------------
select
  case
    when pg_get_functiondef(oid) like '%texto_para_data(p->>''ocorreu_em''%'
      then 'JA CORRIGIDA — usa a funcao tolerante'
    when pg_get_functiondef(oid) like '%(p->>''ocorreu_em'')::timestamptz%'
      then 'PRECISA CORRIGIR — usa cast direto'
    else 'formato inesperado, veja o corpo da funcao'
  end as estado_antes
from pg_proc where proname = 'ingest_venda';

-- ---------------------------------------------------------------------
-- 2. A FUNÇÃO DE DATA ACEITA EPOCH?
-- ---------------------------------------------------------------------
select
  dash.texto_para_data('1787756268398') as epoch_milissegundos,
  dash.texto_para_data('1755882000')    as epoch_segundos;

-- ---------------------------------------------------------------------
-- 3. CORRIGIR
-- ---------------------------------------------------------------------
create or replace function dash.texto_para_data(txt text)
returns timestamptz language plpgsql immutable as $$
declare v text; n bigint;
begin
  v := btrim(coalesce(txt, ''));
  if v = '' or lower(v) in ('null','none','nan','undefined') then return null; end if;

  if v ~ '^\d{1,2}/\d{1,2}/\d{4}' then
    begin
      return to_timestamp(v, 'DD/MM/YYYY HH24:MI:SS');
    exception when others then
      begin
        return to_timestamp(split_part(v, ' ', 1), 'DD/MM/YYYY');
      exception when others then return null; end;
    end;
  end if;

  if v ~ '^\d{1,2}-\d{1,2}-\d{4}' then
    begin
      return to_timestamp(split_part(v, ' ', 1), 'DD-MM-YYYY');
    exception when others then return null; end;
  end if;

  -- epoch: a Hotmart manda milissegundos. Decidir pela grandeza, e não
  -- pela contagem de dígitos, evita erro em datas muito antigas.
  if v ~ '^\d{9,16}$' then
    n := v::bigint;
    if n > 100000000000 then return to_timestamp(n / 1000.0);
    elsif n > 100000000 then return to_timestamp(n);
    else return null;
    end if;
  end if;

  begin
    return v::timestamptz;
  exception when others then return null;
  end;
end $$;

do $bloco$
declare v_def text; v_novo text;
begin
  select pg_get_functiondef(oid) into v_def
  from pg_proc where proname = 'ingest_venda' limit 1;

  if v_def is null then
    raise notice 'ingest_venda nao existe';
    return;
  end if;

  v_novo := replace(
    v_def,
    'coalesce((p->>''ocorreu_em'')::timestamptz, now())',
    'coalesce(dash.texto_para_data(p->>''ocorreu_em''), now())'
  );

  -- também a forma sem coalesce, caso outro arquivo tenha reescrito
  v_novo := replace(
    v_novo,
    '(p->>''ocorreu_em'')::timestamptz',
    'coalesce(dash.texto_para_data(p->>''ocorreu_em''), now())'
  );

  if v_novo = v_def then
    raise notice 'ingest_venda ja estava correta';
  else
    execute v_novo;
    raise notice 'ingest_venda corrigida agora';
  end if;
end $bloco$;

-- ---------------------------------------------------------------------
-- 4. CONFERIR DEPOIS
-- ---------------------------------------------------------------------
select
  case
    when pg_get_functiondef(oid) like '%texto_para_data(p->>''ocorreu_em''%'
      then 'OK — corrigida'
    else 'AINDA COM PROBLEMA — me mande o resultado disto'
  end as estado_depois
from pg_proc where proname = 'ingest_venda';

-- ---------------------------------------------------------------------
-- 5. LIMPAR OS ERROS ANTIGOS QUE NÃO ERAM VENDA
--    Eles poluem a tela de saúde e escondem problema real.
-- ---------------------------------------------------------------------
update dash.webhooks_raw
set processado = true,
    erro = 'ignorado: evento que nao e de compra'
where fonte = 'hotmart'
  and not processado
  and body->>'event' is not null
  and body->>'event' not like 'PURCHASE%';

select count(*) || ' webhooks antigos marcados como ignorados' as limpeza
from dash.webhooks_raw
where fonte = 'hotmart' and erro like 'ignorado%';
