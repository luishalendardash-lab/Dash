-- =====================================================================
-- 57 — DATA DA VENDA VINDA DE WEBHOOK
--
-- O ingest_venda convertia a data com ::timestamptz direto. A Hotmart
-- manda epoch em milissegundos (1755882000000), e o Postgres tenta ler
-- isso como ano — daí o "date/time field value out of range".
--
-- A venda inteira era recusada por causa disso: o webhook voltava 400 e
-- a Hotmart não reenvia. Ou seja, venda perdida em silêncio.
--
-- Agora usa a mesma função tolerante que a importação usa, e a data
-- inválida vira "agora" em vez de derrubar a venda — porque perder o
-- horário exato é muito melhor do que perder a venda.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. A FUNÇÃO TOLERANTE PASSA A ACEITAR MAIS FORMATOS
-- ---------------------------------------------------------------------
create or replace function dash.texto_para_data(txt text)
returns timestamptz language plpgsql immutable as $$
declare v text; n bigint;
begin
  v := btrim(coalesce(txt, ''));
  if v = '' or lower(v) in ('null','none','nan','undefined') then return null; end if;

  -- dd/mm/aaaa, com ou sem hora. Sem isso o Postgres lê mês primeiro e
  -- 11/07 vira 7 de novembro.
  if v ~ '^\d{1,2}/\d{1,2}/\d{4}' then
    begin
      return to_timestamp(v, 'DD/MM/YYYY HH24:MI:SS');
    exception when others then
      begin
        return to_timestamp(split_part(v, ' ', 1), 'DD/MM/YYYY');
      exception when others then return null; end;
    end;
  end if;

  -- dd-mm-aaaa
  if v ~ '^\d{1,2}-\d{1,2}-\d{4}' then
    begin
      return to_timestamp(split_part(v, ' ', 1), 'DD-MM-YYYY');
    exception when others then return null; end;
  end if;

  -- Epoch. A Hotmart usa milissegundos; outras plataformas, segundos.
  -- Decidir pela quantidade de dígitos quebra em datas antigas, então
  -- olhamos a grandeza do número: acima de 10^11 só pode ser ms.
  if v ~ '^\d{9,16}$' then
    n := v::bigint;
    if n > 100000000000 then          -- milissegundos
      return to_timestamp(n / 1000.0);
    elsif n > 100000000 then          -- segundos
      return to_timestamp(n);
    else
      return null;                    -- número pequeno demais para ser data
    end if;
  end if;

  -- ISO e o que o Postgres já entende
  begin
    return v::timestamptz;
  exception when others then
    return null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 2. INGEST_VENDA USA A FUNÇÃO, NÃO O CAST DIRETO
-- ---------------------------------------------------------------------
do $bloco$
declare v_def text;
begin
  select pg_get_functiondef(oid) into v_def
  from pg_proc where proname = 'ingest_venda' limit 1;

  if v_def is null then
    raise notice 'ingest_venda nao encontrada; nada a fazer';
    return;
  end if;

  -- troca o cast por dash.texto_para_data, preservando o resto da função
  v_def := replace(
    v_def,
    'coalesce((p->>''ocorreu_em'')::timestamptz, now())',
    'coalesce(dash.texto_para_data(p->>''ocorreu_em''), now())'
  );

  execute v_def;
  raise notice 'ingest_venda atualizada';
end $bloco$;

-- ---------------------------------------------------------------------
-- 3. CONFERIR
-- ---------------------------------------------------------------------
select
  dash.texto_para_data('1755882000000') as epoch_ms,
  dash.texto_para_data('1755882000')    as epoch_s,
  dash.texto_para_data('22/08/2026')    as brasileira,
  dash.texto_para_data('2026-08-22T14:30:00Z') as iso,
  dash.texto_para_data('')              as vazia,
  dash.texto_para_data('lixo')          as invalida;
