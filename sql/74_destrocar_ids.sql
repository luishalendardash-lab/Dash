-- =====================================================================
-- 74 — DESTROCAR OS IDS
--
-- O diagnóstico foi claro:
--
--   meta_ad_id     casa como CONJUNTO (93)
--   meta_adset_id  casa como ANÚNCIO  (160)
--
-- Os dois estão invertidos. Veio assim da planilha: o formulário gravou
-- utm_content com o id do conjunto e utm_term com o do anúncio, e na
-- importação eu li na ordem errada.
--
-- Um update coloca cada um no seu lugar. Nada se perde: os dois valores
-- continuam no banco, só trocam de campo.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. ANTES
-- ---------------------------------------------------------------------
select
  count(*) filter (where exists (
    select 1 from dash.ads_entidades e
    where e.id = i.meta_ad_id and e.nivel = 'ad')) as ad_id_certo,
  count(*) filter (where exists (
    select 1 from dash.ads_entidades e
    where e.id = i.meta_ad_id and e.nivel = 'adset')) as ad_id_com_conjunto,
  count(*) filter (where exists (
    select 1 from dash.ads_entidades e
    where e.id = i.meta_adset_id and e.nivel = 'ad')) as adset_id_com_anuncio
from dash.inscricoes i;

-- ---------------------------------------------------------------------
-- 2. TROCAR
--    Só onde a inversão é comprovada: o campo de anúncio aponta para um
--    conjunto E o de conjunto aponta para um anúncio. Assim quem está
--    certo não é tocado.
-- ---------------------------------------------------------------------
update dash.inscricoes i
set meta_ad_id = i.meta_adset_id,
    meta_adset_id = i.meta_ad_id
where exists (select 1 from dash.ads_entidades e
              where e.id = i.meta_adset_id and e.nivel = 'ad')
  and (i.meta_ad_id is null
       or exists (select 1 from dash.ads_entidades e
                  where e.id = i.meta_ad_id and e.nivel = 'adset'));

-- ---------------------------------------------------------------------
-- 3. DEPOIS
-- ---------------------------------------------------------------------
select
  count(*) filter (where exists (
    select 1 from dash.ads_entidades e
    where e.id = i.meta_ad_id and e.nivel = 'ad')) as ad_id_certo,
  count(*) filter (where exists (
    select 1 from dash.ads_entidades e
    where e.id = i.meta_ad_id and e.nivel = 'adset')) as ainda_invertido
from dash.inscricoes i;

-- ---------------------------------------------------------------------
-- 4. QUANTO GASTO CASOU
-- ---------------------------------------------------------------------
select
  (select coalesce(round(sum(gasto),2),0) from dash.ads_insights) as investido_total,
  (select coalesce(round(sum(a.gasto),2),0)
   from dash.ads_insights a
   where exists (select 1 from dash.inscricoes i where i.meta_ad_id = a.ad_id))
     as investido_com_lead,
  (select count(distinct i.meta_ad_id)
   from dash.inscricoes i
   join dash.ads_insights a on a.ad_id = i.meta_ad_id) as anuncios_casados;
