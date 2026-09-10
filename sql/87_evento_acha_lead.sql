-- =====================================================================
-- 87 — O EVENTO ENCONTRA O LEAD EM QUALQUER LANÇAMENTO
--
-- O webhook do SendFlow avisa quem entrou no grupo, mas não diz a qual
-- lançamento a pessoa pertence. A função então chutava o lançamento
-- ativo mais recente e procurava a inscrição só ali.
--
-- Quando há mais de um lançamento ativo — ou quando o aviso chega
-- atrasado, depois de o lançamento seguinte começar — a inscrição não é
-- encontrada e o evento fica solto, sem marcar ninguém.
--
-- Agora, se não achar no lançamento presumido, procura a inscrição mais
-- recente daquela pessoa em qualquer lançamento. É o comportamento
-- certo: a pessoa entrou num grupo, e o grupo pertence ao lançamento
-- em que ela se inscreveu.
-- =====================================================================

set search_path = dash, public;

create or replace function public.ingest_evento(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc_id uuid; v_pessoa uuid; v_insc uuid; v_quando timestamptz;
  v_evento_id bigint;   -- eventos.id é bigint, não uuid
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc_id from dash.lancamentos where slug = p->>'lancamento';
  end if;
  if v_lanc_id is null then
    select id into v_lanc_id from dash.lancamentos
    where status in ('captacao','aquecimento','evento','carrinho')
    order by criado_em desc limit 1;
  end if;

  v_quando := coalesce(dash.texto_para_data(p->>'ocorreu_em'), now());

  if p ? 'inscricao_id' and nullif(p->>'inscricao_id','') is not null then
    select id, pessoa_id, lancamento_id into v_insc, v_pessoa, v_lanc_id
    from dash.inscricoes where id = (p->>'inscricao_id')::uuid;
  else
    begin
      v_pessoa := dash.upsert_pessoa(p->>'email', p->>'telefone', p->>'nome');
    exception when others then
      return jsonb_build_object('ok', false, 'erro', 'sem identificador');
    end;

    -- primeiro no lançamento presumido
    select id into v_insc from dash.inscricoes
    where pessoa_id = v_pessoa and lancamento_id = v_lanc_id
    order by capturado_em desc
    limit 1;

    -- Não achou: a pessoa pode ser de outro lançamento. O aviso do
    -- SendFlow não diz qual, então usamos a inscrição mais recente
    -- dela — que é onde o grupo dela está.
    if v_insc is null then
      select i.id, i.lancamento_id
      into v_insc, v_lanc_id
      from dash.inscricoes i
      where i.pessoa_id = v_pessoa
      order by i.capturado_em desc
      limit 1;
    end if;
  end if;

  if v_pessoa is null then
    return jsonb_build_object('ok', false, 'erro', 'pessoa nao resolvida');
  end if;

  insert into dash.eventos
    (lancamento_id, pessoa_id, inscricao_id, tipo, ocorreu_em, fonte, payload, dedupe_key)
  values (
    v_lanc_id, v_pessoa, v_insc,
    coalesce(nullif(p->>'tipo',''), 'evento'),
    v_quando,
    coalesce(nullif(p->>'fonte',''), 'externo'),
    coalesce(p->'payload', '{}'::jsonb),
    nullif(p->>'dedupe_key','')
  )
  on conflict (dedupe_key) do nothing
  returning id into v_evento_id;

  return jsonb_build_object(
    'ok', true,
    'pessoa_id', v_pessoa,
    'inscricao_id', v_insc,
    'evento_id', v_evento_id,
    -- quando não há inscrição, o evento é gravado mas não marca
    -- ninguém: a pessoa entrou no grupo sem ter se inscrito
    'sem_inscricao', v_insc is null
  );
end $$;

grant execute on function public.ingest_evento(jsonb) to service_role, anon, authenticated;

-- ---------------------------------------------------------------------
-- Aplicar nos eventos que ficaram sem inscrição
-- ---------------------------------------------------------------------
update dash.eventos e set
  inscricao_id = i.id,
  lancamento_id = coalesce(e.lancamento_id, i.lancamento_id)
from dash.inscricoes i
where e.inscricao_id is null
  and e.pessoa_id = i.pessoa_id
  and e.tipo in ('grupo_entrou', 'grupo_saiu')
  and i.id = (
    select id from dash.inscricoes i2
    where i2.pessoa_id = e.pessoa_id
    order by capturado_em desc limit 1
  );

-- e marcar quem passou a ter inscrição
update dash.inscricoes i set
  entrou_grupo = true,
  grupo_em = coalesce(i.grupo_em, e.ocorreu_em),
  grupo_nome = coalesce(i.grupo_nome, nullif(e.payload->>'grupo',''))
from dash.eventos e
where e.inscricao_id = i.id
  and e.tipo = 'grupo_entrou'
  and not coalesce(i.entrou_grupo, false);

notify pgrst, 'reload schema';

select
  (select count(*) from dash.eventos where tipo='grupo_entrou') as eventos,
  (select count(*) from dash.eventos where tipo='grupo_entrou' and inscricao_id is null) as sem_lead,
  (select count(*) from dash.inscricoes where entrou_grupo) as leads_no_grupo;
