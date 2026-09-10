-- =====================================================================
-- 85 — RECUPERAR AS ENTRADAS NO GRUPO QUE FALHARAM
--
-- O parser procurava o telefone em "phone", "telefone" e afins. O
-- SendFlow chama o campo de "number", dentro de "data" — então nenhum
-- aviso de entrada no grupo era aproveitado, e todos viravam
-- "sem identificador".
--
-- Os avisos ficaram guardados. Este arquivo os reprocessa, e marca os
-- de estatística como ignorados em vez de erro.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. O QUE ESTÁ PARADO
-- ---------------------------------------------------------------------
select
  body->>'event' as evento,
  count(*) as quantidade,
  min(recebido_em)::date as primeiro,
  max(recebido_em)::date as ultimo
from dash.webhooks_raw
where fonte = 'sendflow' and not processado
group by 1
order by 2 desc;

-- ---------------------------------------------------------------------
-- 2. REPROCESSAR AS ENTRADAS
-- ---------------------------------------------------------------------
create or replace function public.reprocessar_sendflow(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  r record; v_res jsonb; v_fone text; v_evento text;
  v_ok int := 0; v_ignorados int := 0; v_sem_lead int := 0; v_erro text;
begin
  for r in
    select * from dash.webhooks_raw
    where fonte = 'sendflow' and not processado
    order by recebido_em
    limit coalesce(nullif(p->>'limite','')::int, 2000)
  loop
    v_evento := coalesce(r.body->>'event', '');

    -- estatística de campanha não é pessoa entrando no grupo
    if v_evento like '%metric%' then
      update dash.webhooks_raw
      set processado = true, erro = 'ignorado: ' || v_evento
      where id = r.id;
      v_ignorados := v_ignorados + 1;
      continue;
    end if;

    v_fone := dash.norm_phone(coalesce(
      r.body->'data'->>'number',
      r.body->'data'->>'phone',
      r.body->>'number'
    ));

    if v_fone is null then
      update dash.webhooks_raw
      set processado = true, erro = 'ignorado: aviso sem telefone (' || v_evento || ')'
      where id = r.id;
      v_ignorados := v_ignorados + 1;
      continue;
    end if;

    begin
      v_res := public.ingest_evento(jsonb_build_object(
        'telefone', v_fone,
        'tipo', case when v_evento ~ '(removed|left)' then 'grupo_saiu'
                     else 'grupo_entrou' end,
        'fonte', 'sendflow',
        'ocorreu_em', coalesce(r.body->'data'->>'createdAt', r.recebido_em::text),
        'payload', jsonb_build_object(
          'grupo', r.body->'data'->>'groupName',
          'grupo_id', r.body->'data'->>'groupId',
          'campanha', r.body->'data'->>'campaignName'
        ),
        'dedupe_key', 'sendflow:raw:' || r.id
      ));

      if coalesce((v_res->>'ok')::boolean, false) then
        update dash.webhooks_raw set processado = true, erro = null where id = r.id;
        v_ok := v_ok + 1;
      else
        -- telefone que não corresponde a nenhum lead: a pessoa entrou no
        -- grupo sem ter passado pela captura
        v_sem_lead := v_sem_lead + 1;
        v_erro := coalesce(v_erro, v_res->>'erro');
        update dash.webhooks_raw
        set processado = true,
            erro = 'telefone sem lead correspondente: ' || v_fone
        where id = r.id;
      end if;

    exception when others then
      v_erro := coalesce(v_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'entradas_registradas', v_ok,
    'ignorados', v_ignorados,
    'telefone_sem_lead', v_sem_lead,
    'primeiro_erro', v_erro,
    'ainda_pendentes', (select count(*) from dash.webhooks_raw
                        where fonte = 'sendflow' and not processado)
  );
end $$;

revoke all on function public.reprocessar_sendflow(jsonb) from public, anon, authenticated;
grant execute on function public.reprocessar_sendflow(jsonb) to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 3. RODAR
-- ---------------------------------------------------------------------
select jsonb_pretty(public.reprocessar_sendflow('{}'::jsonb));
