-- =====================================================================
-- 86 — O EVENTO PASSA A MARCAR O LEAD
--
-- O ingest_evento gravava o aviso de entrada no grupo na tabela de
-- eventos, mas nunca tocava em inscricoes.entrou_grupo. Ou seja: o dado
-- chegava, era guardado, e a dash continuava mostrando que ninguém
-- entrou.
--
-- Isso soma ao outro problema (o parser não lia "number"): mesmo depois
-- de ler o telefone certo, a marcação não aconteceria.
--
-- Um gatilho resolve para sempre — vale para o webhook, para o
-- reprocessamento e para qualquer caminho futuro.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. GATILHO
-- ---------------------------------------------------------------------
create or replace function dash.marcar_grupo_no_evento()
returns trigger language plpgsql as $$
begin
  if new.inscricao_id is null then return new; end if;

  if new.tipo = 'grupo_entrou' then
    update dash.inscricoes set
      entrou_grupo = true,
      grupo_em = coalesce(grupo_em, new.ocorreu_em, now()),
      grupo_nome = coalesce(nullif(new.payload->>'grupo',''), grupo_nome)
    where id = new.inscricao_id;

  elsif new.tipo = 'grupo_saiu' then
    -- saiu depois de entrar: guardamos que saiu, sem apagar a entrada.
    -- Quem entrou e saiu é informação diferente de quem nunca entrou.
    update dash.inscricoes set
      saiu_grupo_em = coalesce(new.ocorreu_em, now())
    where id = new.inscricao_id;
  end if;

  return new;
end $$;

-- a coluna de saída pode não existir ainda
do $bloco$
begin
  alter table dash.inscricoes add column if not exists saiu_grupo_em timestamptz;
exception when others then null;
end $bloco$;

drop trigger if exists tg_marcar_grupo on dash.eventos;

create trigger tg_marcar_grupo
after insert on dash.eventos
for each row execute function dash.marcar_grupo_no_evento();

-- ---------------------------------------------------------------------
-- 2. APLICAR NO QUE JÁ ESTÁ GRAVADO
--    Os eventos que chegaram antes do gatilho existirem.
-- ---------------------------------------------------------------------
update dash.inscricoes i set
  entrou_grupo = true,
  grupo_em = coalesce(i.grupo_em, e.ocorreu_em),
  grupo_nome = coalesce(i.grupo_nome, nullif(e.payload->>'grupo',''))
from dash.eventos e
where e.inscricao_id = i.id
  and e.tipo = 'grupo_entrou'
  and not coalesce(i.entrou_grupo, false);

update dash.inscricoes i set
  saiu_grupo_em = coalesce(i.saiu_grupo_em, e.ocorreu_em)
from dash.eventos e
where e.inscricao_id = i.id
  and e.tipo = 'grupo_saiu'
  and i.saiu_grupo_em is null;

-- ---------------------------------------------------------------------
-- 3. CONFERIR
-- ---------------------------------------------------------------------
select
  count(*) filter (where tipo = 'grupo_entrou') as eventos_de_entrada,
  (select count(*) from dash.inscricoes where entrou_grupo) as leads_marcados,
  (select count(*) from dash.inscricoes where saiu_grupo_em is not null) as sairam
from dash.eventos;
