-- =====================================================================
-- 69 — CAMPOS TROCADOS NA IMPORTAÇÃO
--
-- O diagnóstico mostrou que os leads estão com os valores no campo
-- errado:
--
--   meta_ad_id  guarda "00-[27.11.25][SEMELHANTE][ALUNOS-1%]"  (conjunto)
--   utm_content guarda "120230028415270179"                     (o ID)
--
-- Além disso alguns nomes vieram com escape de URL: %5BADS10%5D em vez
-- de [ADS10]. Isso vem da planilha, que gravou a UTM sem decodificar.
--
-- Sem corrigir, o gasto nunca casa: a dash procura o ID num campo que
-- tem nome, e o nome num campo que tem ID.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. DECODIFICAR ESCAPE DE URL
--    %5BADS10%5D vira [ADS10]
-- ---------------------------------------------------------------------
create or replace function dash.decodificar_url(txt text)
returns text language plpgsql immutable as $$
declare v text; par text[]; achado text;
begin
  v := coalesce(txt, '');
  if v = '' or position('%' in v) = 0 then return nullif(btrim(v), ''); end if;

  v := replace(v, '+', ' ');

  -- Troca cada %XX pelo caractere correspondente, um a um.
  --
  -- A conversão em bloco com decode(..., 'escape') não serve: ela espera
  -- a sintaxe de bytea do Postgres, não texto com percentuais, e recusa
  -- a entrada inteira. Substituir um por vez é mais lento e funciona
  -- com qualquer mistura de texto e código.
  loop
    par := regexp_match(v, '%([0-9a-fA-F]{2})');
    exit when par is null;
    begin
      achado := chr(('x' || par[1])::bit(8)::int);
    exception when others then
      exit;
    end;
    v := replace(v, '%' || par[1], achado);
  end loop;

  return nullif(btrim(v), '');
end $$;

-- ---------------------------------------------------------------------
-- 2. VER O ESTRAGO ANTES DE MEXER
-- ---------------------------------------------------------------------
select
  count(*) as leads,
  count(*) filter (where meta_ad_id !~ '^[0-9]+$' and meta_ad_id is not null)
    as id_com_texto,
  count(*) filter (where utm_content ~ '^[0-9]+$') as content_com_numero,
  count(*) filter (where utm_content like '%\%5B%' or utm_content like '%\%20%')
    as com_escape_url
from dash.inscricoes;

-- ---------------------------------------------------------------------
-- 3. DESTROCAR
--    Só onde os dois estão claramente invertidos: id com texto e
--    content com número. Assim não mexemos em quem está certo.
-- ---------------------------------------------------------------------
update dash.inscricoes
set meta_ad_id = utm_content,
    meta_adset_id = coalesce(meta_adset_id, meta_ad_id),
    utm_content = dash.decodificar_url(utm_medium)
where meta_ad_id is not null
  and meta_ad_id !~ '^[0-9]+$'
  and utm_content ~ '^[0-9]+$';

-- ---------------------------------------------------------------------
-- 4. DECODIFICAR O QUE SOBROU COM ESCAPE
-- ---------------------------------------------------------------------
update dash.inscricoes
set utm_content = dash.decodificar_url(utm_content)
where utm_content like '%\%%';

update dash.inscricoes
set utm_campaign = dash.decodificar_url(utm_campaign)
where utm_campaign like '%\%%';

update dash.inscricoes
set utm_medium = dash.decodificar_url(utm_medium)
where utm_medium like '%\%%';

update dash.inscricoes
set utm_source = dash.decodificar_url(utm_source)
where utm_source like '%\%%';

-- ---------------------------------------------------------------------
-- 4b. VARIÁVEL DO META QUE NÃO FOI SUBSTITUÍDA
--
-- Quando a UTM da campanha é montada com {{ad.name}} e o Meta não
-- substitui — acontece quando o anúncio é criado por API ou duplicado —
-- o lead chega com o texto literal. Isso vira um "criativo" fantasma na
-- tela, com dezenas de leads e nenhum gasto.
--
-- Limpamos o texto para o lead cair em "(sem anuncio)", que é honesto:
-- ele veio de anúncio, mas não sabemos qual.
-- ---------------------------------------------------------------------
update dash.inscricoes
set utm_content = null
where utm_content like '%{{%' or utm_content like '%}}%';

update dash.inscricoes
set meta_ad_id = null
where meta_ad_id like '%{{%' or meta_ad_id like '%}}%';

update dash.inscricoes
set utm_campaign = null
where utm_campaign like '%{{%' or utm_campaign like '%}}%';

update dash.inscricoes
set utm_medium = null
where utm_medium like '%{{%' or utm_medium like '%}}%';

-- ---------------------------------------------------------------------
-- 5. COMO FICOU
-- ---------------------------------------------------------------------
select
  count(*) as leads,
  count(*) filter (where meta_ad_id ~ '^[0-9]+$') as id_numerico_ok,
  count(*) filter (where meta_ad_id !~ '^[0-9]+$' and meta_ad_id is not null)
    as ainda_com_texto,
  count(*) filter (where utm_content like '%\%%') as ainda_com_escape,
  count(*) filter (where utm_content like '%{{%') as variavel_nao_substituida
from dash.inscricoes;

-- ---------------------------------------------------------------------
-- 6. E AGORA CASA?
-- ---------------------------------------------------------------------
select jsonb_pretty(public.diagnostico_gasto('{"lancamento":"fpee-2025-09"}'::jsonb));
