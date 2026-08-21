-- =====================================================================
-- 42 — IMPORTAR O ARQUIVO CONSOLIDADO
--
-- Um arquivo, todos os lançamentos. Cada linha traz o lançamento a que
-- pertence, então não há seletor nem mapeamento para errar.
--
-- Roda por cima do que já existe: completa quem está lá, cria quem
-- falta, e não duplica ninguém.
-- =====================================================================

set search_path = dash, public;

create or replace function public.importar_consolidado(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_linha jsonb; v_lanc uuid; v_slug text;
  v_email text; v_fone text; v_data timestamptz;
  v_pessoa uuid; v_insc uuid; v_eng boolean; v_tem_form boolean;
  v_chave text; v_valor text;
  v_novos int := 0; v_completados int := 0; v_erros int := 0;
  v_engs int := 0; v_resp int := 0; v_sem_lanc int := 0;
  v_primeiro_erro text; v_por_lanc jsonb := '{}'::jsonb;
begin
  for v_linha in select * from jsonb_array_elements(
    case when jsonb_typeof(p->'linhas') = 'array' then p->'linhas' else '[]'::jsonb end
  )
  loop
    begin
      v_slug := nullif(btrim(v_linha->>'lancamento'), '');
      select id into v_lanc from dash.lancamentos where slug = v_slug;
      if v_lanc is null then
        v_sem_lanc := v_sem_lanc + 1;
        v_primeiro_erro := coalesce(v_primeiro_erro,
          'lancamento nao encontrado: ' || coalesce(v_slug, '(vazio)'));
        continue;
      end if;

      v_email := dash.norm_email(v_linha->>'email');
      v_fone  := dash.norm_phone(v_linha->>'telefone');
      if v_email is null and v_fone is null then
        v_erros := v_erros + 1;
        continue;
      end if;

      v_data := dash.texto_para_data(v_linha->>'data');
      v_tem_form := nullif(btrim(v_linha->>'formacao'), '') is not null;
      v_eng := lower(btrim(coalesce(v_linha->>'engenheiro',''))) in ('sim','true','1');

      -- pessoa: e-mail primeiro, telefone como reserva
      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      if v_pessoa is null then
        insert into dash.pessoas (nome, email, telefone, criado_em)
        values (nullif(btrim(v_linha->>'nome'),''), v_email, v_fone,
                coalesce(v_data, now()))
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

      if v_insc is null then
        insert into dash.inscricoes (
          lancamento_id, pessoa_id, capturado_em, data_aproximada,
          utm_source, utm_medium, utm_campaign, utm_content,
          meta_campaign_id, meta_adset_id, meta_ad_id,
          origem_sistema, engenheiro, fez_quiz, comprou
        ) values (
          v_lanc, v_pessoa, coalesce(v_data, now()), v_data is null,
          nullif(btrim(v_linha->>'campanha'),''),
          nullif(btrim(v_linha->>'conjunto'),''),
          nullif(btrim(v_linha->>'campanha'),''),
          nullif(btrim(v_linha->>'anuncio'),''),
          nullif(btrim(v_linha->>'campanha_id'),''),
          nullif(btrim(v_linha->>'conjunto_id'),''),
          nullif(btrim(v_linha->>'anuncio_id'),''),
          'importacao', v_eng,
          lower(coalesce(v_linha->>'fez_quiz','')) = 'sim',
          false
        )
        returning id into v_insc;
        v_novos := v_novos + 1;

        insert into dash.eventos
          (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key)
        values (v_insc, v_pessoa, v_lanc, 'captura', 'importacao',
                coalesce(v_data, now()), 'importado:' || v_insc::text)
        on conflict (dedupe_key) do nothing;
      else
        -- completa o que falta, sem sobrescrever o que já está certo
        update dash.inscricoes set
          utm_source   = coalesce(utm_source,   nullif(btrim(v_linha->>'campanha'),'')),
          utm_medium   = coalesce(utm_medium,   nullif(btrim(v_linha->>'conjunto'),'')),
          utm_campaign = coalesce(utm_campaign, nullif(btrim(v_linha->>'campanha'),'')),
          utm_content  = coalesce(utm_content,  nullif(btrim(v_linha->>'anuncio'),'')),
          meta_campaign_id = coalesce(meta_campaign_id, nullif(btrim(v_linha->>'campanha_id'),'')),
          meta_adset_id = coalesce(meta_adset_id, nullif(btrim(v_linha->>'conjunto_id'),'')),
          meta_ad_id   = coalesce(meta_ad_id,   nullif(btrim(v_linha->>'anuncio_id'),'')),
          -- a formação é resposta do lead: quando vem, vale
          engenheiro   = case when v_tem_form then v_eng else engenheiro end,
          fez_quiz     = fez_quiz or lower(coalesce(v_linha->>'fez_quiz','')) = 'sim',
          capturado_em = case when data_aproximada and v_data is not null
                              then v_data else capturado_em end,
          data_aproximada = case when data_aproximada and v_data is not null
                                 then false else data_aproximada end,
          atualizado_em = now()
        where id = v_insc;
        v_completados := v_completados + 1;
      end if;

      if v_eng then v_engs := v_engs + 1; end if;

      -- respostas do quiz: toda chave que começa com r_
      for v_chave, v_valor in select key, value from jsonb_each_text(v_linha)
      loop
        continue when left(v_chave, 2) <> 'r_';
        continue when btrim(coalesce(v_valor,'')) = '';
        insert into dash.quiz_respostas_livres (inscricao_id, pergunta, resposta)
        values (v_insc, replace(substr(v_chave, 3), '_', ' '), btrim(v_valor))
        on conflict (inscricao_id, pergunta) do update set resposta = excluded.resposta;
        v_resp := v_resp + 1;
      end loop;

      v_por_lanc := jsonb_set(v_por_lanc, array[v_slug],
        to_jsonb(coalesce((v_por_lanc->>v_slug)::int, 0) + 1));

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true, 'novos', v_novos, 'completados', v_completados,
    'engenheiros', v_engs, 'respostas', v_resp,
    'sem_lancamento', v_sem_lanc, 'erros', v_erros,
    'primeiro_erro', v_primeiro_erro, 'por_lancamento', v_por_lanc
  );
end $$;

revoke all on function public.importar_consolidado(jsonb) from public, anon, authenticated;
grant execute on function public.importar_consolidado(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- INVESTIMENTO POR DIA
--   p: { lancamento, dias: [{data, valor}] }
-- Para quando existe o total diário mas não a quebra por criativo.
-- ---------------------------------------------------------------------
create or replace function public.lancar_investimento_diario(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_item jsonb; v_qtd int := 0; v_total numeric := 0; v_chave text;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  -- entra como uma entidade só: o gasto é do lançamento, não de um criativo
  v_chave := 'geral-' || (p->>'lancamento');
  insert into dash.ads_entidades (id, lancamento_id, nivel, nome, conta_id)
  values (v_chave, v_lanc, 'ad', 'Investimento total do lançamento', 'manual')
  on conflict (id) do nothing;

  for v_item in select * from jsonb_array_elements(coalesce(p->'dias','[]'::jsonb))
  loop
    insert into dash.ads_insights (ad_id, lancamento_id, data_ref, gasto, impressoes, cliques)
    values (v_chave, v_lanc,
            dash.texto_para_data(v_item->>'data')::date,
            coalesce(dash.valor_para_numero(v_item->>'valor'), 0), 0, 0)
    on conflict (ad_id, data_ref) do update set gasto = excluded.gasto;
    v_qtd := v_qtd + 1;
    v_total := v_total + coalesce(dash.valor_para_numero(v_item->>'valor'), 0);
  end loop;

  return jsonb_build_object('ok', true, 'dias', v_qtd, 'total', round(v_total, 2));
end $$;

revoke all on function public.lancar_investimento_diario(jsonb) from public, anon, authenticated;
grant execute on function public.lancar_investimento_diario(jsonb) to service_role;

select 'pronto' as status;
