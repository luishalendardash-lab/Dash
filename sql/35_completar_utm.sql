-- =====================================================================
-- 35 — COMPLETAR UTM DE LEADS EXISTENTES
--
-- A importação por tags traz quem participou de cada lançamento, mas o
-- export do SellFlux não tem UTM. A planilha do formulário de captura
-- tem — só que, ao importar por cima, o lead era detectado como
-- repetido e pulado sem preencher nada.
--
-- Agora, quando a inscrição já existe, os campos VAZIOS são completados.
-- O que já tem valor não é sobrescrito: dado antigo pode estar certo e
-- a planilha nova, incompleta.
-- =====================================================================

set search_path = dash, public;

create or replace function public.importar_leads(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_linha jsonb;
  v_email text; v_fone text; v_data timestamptz;
  v_pessoa uuid; v_insc uuid;
  v_novos int := 0; v_completados int := 0; v_iguais int := 0;
  v_erros int := 0; v_primeiro_erro text;
  v_tinha_utm boolean;
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
      v_fone  := dash.norm_phone(v_linha->>'telefone');

      if v_email is null and v_fone is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro, 'linha sem email e sem telefone');
        continue;
      end if;

      v_data := dash.texto_para_data(v_linha->>'data');

      -- pessoa: e-mail primeiro
      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      if v_pessoa is null then
        -- lead novo precisa de data: sem ela o histórico mente
        if v_data is null then
          v_erros := v_erros + 1;
          v_primeiro_erro := coalesce(v_primeiro_erro,
            'data invalida: ' || coalesce(v_linha->>'data','(vazia)'));
          continue;
        end if;
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

      select id into v_insc from dash.inscricoes
      where pessoa_id = v_pessoa and lancamento_id = v_lanc;

      -- ---- já participa: completa o que está faltando
      if v_insc is not null then
        select (utm_campaign is not null or meta_ad_id is not null)
        into v_tinha_utm from dash.inscricoes where id = v_insc;

        update dash.inscricoes set
          utm_source   = coalesce(utm_source,   nullif(btrim(v_linha->>'utm_source'),'')),
          utm_medium   = coalesce(utm_medium,   nullif(btrim(v_linha->>'utm_medium'),'')),
          utm_campaign = coalesce(utm_campaign, nullif(btrim(v_linha->>'utm_campaign'),'')),
          utm_content  = coalesce(utm_content,  nullif(btrim(v_linha->>'utm_content'),'')),
          utm_term     = coalesce(utm_term,     nullif(btrim(v_linha->>'utm_term'),'')),
          meta_ad_id   = coalesce(meta_ad_id,   nullif(btrim(v_linha->>'ad_id'),'')),
          -- a data da planilha do formulário é a captura real; a que veio
          -- da tag é aproximada, então essa vence
          capturado_em = case when data_aproximada and v_data is not null
                              then v_data else capturado_em end,
          data_aproximada = case when data_aproximada and v_data is not null
                                 then false else data_aproximada end,
          atualizado_em = now()
        where id = v_insc;

        -- contou como completado se antes não tinha origem e agora tem
        if not v_tinha_utm and (
             nullif(btrim(v_linha->>'utm_campaign'),'') is not null
             or nullif(btrim(v_linha->>'ad_id'),'') is not null)
        then
          v_completados := v_completados + 1;
        else
          v_iguais := v_iguais + 1;
        end if;
        continue;
      end if;

      -- ---- participação nova
      if v_data is null then
        v_erros := v_erros + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'data invalida: ' || coalesce(v_linha->>'data','(vazia)'));
        continue;
      end if;

      insert into dash.inscricoes (
        lancamento_id, pessoa_id, capturado_em, data_aproximada,
        utm_source, utm_medium, utm_campaign, utm_content, utm_term,
        meta_ad_id, origem_sistema, comprou
      ) values (
        v_lanc, v_pessoa, v_data, false,
        nullif(btrim(v_linha->>'utm_source'),''),
        nullif(btrim(v_linha->>'utm_medium'),''),
        nullif(btrim(v_linha->>'utm_campaign'),''),
        nullif(btrim(v_linha->>'utm_content'),''),
        nullif(btrim(v_linha->>'utm_term'),''),
        nullif(btrim(v_linha->>'ad_id'),''),
        'importacao', false
      )
      returning id into v_insc;

      insert into dash.eventos
        (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key)
      values (v_insc, v_pessoa, v_lanc, 'captura', 'importacao', v_data,
              'importado:' || v_insc::text)
      on conflict (dedupe_key) do nothing;

      v_novos := v_novos + 1;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'novos', v_novos,
    'completados', v_completados,
    'repetidos', v_iguais,
    'erros', v_erros,
    'primeiro_erro', v_primeiro_erro
  );
end $$;

-- ---------------------------------------------------------------------
-- QUANTOS LEADS TÊM ORIGEM, POR LANÇAMENTO
-- Para conferir o antes e depois de completar as UTMs.
-- ---------------------------------------------------------------------
create or replace function public.cobertura_utm(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'lancamento', nome, 'slug', slug,
    'leads', leads,
    'com_utm', com_utm,
    'com_anuncio', com_ad,
    'cobertura', case when leads > 0 then round(100.0 * com_utm / leads, 1) end,
    'data_aproximada', aprox
  ) order by inicio)
  into v_res
  from (
    select l.nome, l.slug, coalesce(l.captacao_inicio, l.criado_em) as inicio,
      count(*) as leads,
      count(*) filter (where i.utm_campaign is not null) as com_utm,
      count(*) filter (where i.meta_ad_id is not null) as com_ad,
      count(*) filter (where i.data_aproximada) as aprox
    from dash.inscricoes i
    join dash.lancamentos l on l.id = i.lancamento_id
    group by l.nome, l.slug, l.captacao_inicio, l.criado_em
  ) t;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

revoke all on function public.cobertura_utm(jsonb) from public, anon, authenticated;
grant execute on function public.importar_leads(jsonb), public.cobertura_utm(jsonb)
  to service_role;
