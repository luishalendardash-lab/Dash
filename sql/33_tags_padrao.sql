-- =====================================================================
-- 33 — IMPORTAR POR PADRÃO DE TAG
--
-- Substitui o mapeamento tag-a-tag do arquivo 32.
--
-- Motivo: o export real do SellFlux tem 289 tags distintas, e o mesmo
-- lançamento aparece em várias delas — "lead-simples-05-26",
-- "iniciou-form-fpee-05-26", "chegou-fim-quiz-05-26". Mapear uma a uma
-- não é viável; por padrão são 5 regras.
--
-- As tags também revelam mais do que participação:
--   quem chegou ao fim do quiz
--   quem é engenheiro
--   quem comprou
-- Tudo isso entra junto, sem precisar de outro arquivo.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. IMPORTAR
--    p: {
--      linhas: [ {nome,email,telefone,data,tags} ],
--      regras: [ {padrao:'05-26', lancamento:'fpee-2026-05'}, ... ],
--      padrao_engenheiro: 'engenheiro',
--      padrao_nao_engenheiro: 'nao-e-engenheiro|nao-engenheiro',
--      padrao_quiz: 'chegou-fim-quiz',
--      padrao_compra: 'compra-realizada|comprou-',
--      lancamento_da_data: 'fpee-2026-07'
--    }
-- ---------------------------------------------------------------------
create or replace function public.importar_tags_padrao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_linha jsonb; v_regra jsonb;
  v_email text; v_fone text; v_data timestamptz; v_tags text;
  v_pessoa uuid; v_insc uuid; v_lanc uuid; v_quando timestamptz;
  v_slug text; v_padrao text; v_lanc_data text;
  v_eng boolean; v_nao_eng boolean; v_quiz boolean; v_comprou boolean;
  v_pessoas int := 0; v_part int := 0; v_erros int := 0;
  v_sem_tag int := 0; v_compras int := 0; v_engs int := 0;
  v_primeiro_erro text;
  p_eng text; p_nao_eng text; p_quiz text; p_compra text;
begin
  v_lanc_data := nullif(p->>'lancamento_da_data','');
  p_eng      := coalesce(nullif(p->>'padrao_engenheiro',''), 'engenheiro');
  p_nao_eng  := coalesce(nullif(p->>'padrao_nao_engenheiro',''), 'nao-e-engenheiro|nao-engenheiro');
  p_quiz     := coalesce(nullif(p->>'padrao_quiz',''), 'chegou-fim-quiz|fim-quiz');
  p_compra   := coalesce(nullif(p->>'padrao_compra',''), 'compra-realizada|comprou-');

  if jsonb_array_length(coalesce(p->'regras','[]'::jsonb)) = 0 then
    return jsonb_build_object('ok', false, 'erro', 'informe ao menos uma regra de tag');
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

      -- o export traz as tags como JSON: ["a","b"]. Trocamos os
      -- separadores por vírgula para a busca por padrão funcionar igual
      -- em qualquer formato.
      v_tags := lower(coalesce(v_linha->>'tags', ''));
      v_tags := replace(replace(replace(replace(v_tags,
                '[', ','), ']', ','), '"', ''), '''', '');
      v_tags := replace(replace(v_tags, ';', ','), '|', ',');

      if btrim(v_tags, ' ,') = '' then v_sem_tag := v_sem_tag + 1; end if;

      v_data := dash.texto_para_data(v_linha->>'data');

      -- sinais que valem para a pessoa toda
      v_eng     := v_tags ~ p_eng and not (v_tags ~ p_nao_eng);
      v_nao_eng := v_tags ~ p_nao_eng;
      v_quiz    := v_tags ~ p_quiz;
      v_comprou := v_tags ~ p_compra;

      -- pessoa: e-mail primeiro
      v_pessoa := null;
      if v_email is not null then
        select id into v_pessoa from dash.pessoas where email = v_email limit 1;
      end if;
      if v_pessoa is null and v_fone is not null then
        select id into v_pessoa from dash.pessoas where telefone = v_fone limit 1;
      end if;

      if v_pessoa is null then
        insert into dash.pessoas (nome, email, telefone, criado_em)
        values (nullif(btrim(v_linha->>'nome'),''), v_email, v_fone, coalesce(v_data, now()))
        returning id into v_pessoa;
        v_pessoas := v_pessoas + 1;
      else
        update dash.pessoas set
          nome = coalesce(nome, nullif(btrim(v_linha->>'nome'),'')),
          email = coalesce(email, v_email),
          telefone = coalesce(telefone, v_fone)
        where id = v_pessoa;
      end if;

      -- uma participação por regra que casar
      for v_regra in select * from jsonb_array_elements(p->'regras')
      loop
        v_padrao := lower(nullif(btrim(v_regra->>'padrao'),''));
        v_slug := nullif(btrim(v_regra->>'lancamento'),'');
        continue when v_padrao is null or v_slug is null;
        continue when v_tags !~ v_padrao;

        select id, coalesce(captacao_inicio, criado_em) into v_lanc, v_quando
        from dash.lancamentos where slug = v_slug;
        continue when v_lanc is null;

        select id into v_insc from dash.inscricoes
        where pessoa_id = v_pessoa and lancamento_id = v_lanc;

        if v_insc is not null then
          -- já existe: completa o que a tag revelou
          update dash.inscricoes set
            engenheiro = case when v_eng then true
                              when v_nao_eng then false else engenheiro end,
            fez_quiz = fez_quiz or v_quiz
          where id = v_insc;
          continue;
        end if;

        insert into dash.inscricoes (
          lancamento_id, pessoa_id, capturado_em, data_aproximada,
          utm_source, utm_medium, utm_campaign, utm_content,
          origem_sistema, engenheiro, fez_quiz, comprou
        ) values (
          v_lanc, v_pessoa,
          case when v_slug = v_lanc_data and v_data is not null
               then v_data else v_quando end,
          not (v_slug = v_lanc_data and v_data is not null),
          nullif(btrim(v_linha->>'utm_source'),''),
          nullif(btrim(v_linha->>'utm_medium'),''),
          nullif(btrim(v_linha->>'utm_campaign'),''),
          nullif(btrim(v_linha->>'utm_content'),''),
          'importacao',
          -- a coluna nao aceita nulo: sem tag, assume que nao e
          coalesce(case when v_eng then true when v_nao_eng then false end, false),
          v_quiz,
          -- a tag de compra não diz de qual lançamento foi; marcamos no
          -- lançamento cuja data é a do arquivo, que é o mais recente
          false   -- a compra e marcada depois, no ultimo lancamento
        )
        returning id into v_insc;

        insert into dash.eventos
          (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key)
        values (v_insc, v_pessoa, v_lanc, 'captura', 'importacao',
                coalesce(v_data, v_quando), 'importado:' || v_insc::text)
        on conflict (dedupe_key) do nothing;

        if v_quiz then
          insert into dash.eventos
            (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key)
          values (v_insc, v_pessoa, v_lanc, 'quiz_respondido', 'importacao',
                  coalesce(v_data, v_quando), 'impquiz:' || v_insc::text)
          on conflict (dedupe_key) do nothing;
        end if;

        v_part := v_part + 1;
      end loop;

      if v_eng then v_engs := v_engs + 1; end if;

      -- A tag de compra não diz de qual lançamento foi. Atribuímos ao
      -- último lançamento em que a pessoa participou, que é onde a
      -- compra quase sempre acontece. Sem isso, a compra ficaria presa
      -- num lançamento fixo e a recorrência sairia errada.
      if v_comprou then
        v_compras := v_compras + 1;
        update dash.inscricoes set comprou = true, etapa = 'comprou'
        where id = (
          select i.id from dash.inscricoes i
          join dash.lancamentos l on l.id = i.lancamento_id
          where i.pessoa_id = v_pessoa
          order by coalesce(l.captacao_inicio, l.criado_em) desc
          limit 1
        );
      end if;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'pessoas_novas', v_pessoas,
    'participacoes', v_part,
    'engenheiros', v_engs,
    'com_tag_de_compra', v_compras,
    'linhas_sem_tag', v_sem_tag,
    'erros', v_erros,
    'primeiro_erro', v_primeiro_erro
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. TAGS DO LOTE — agora entende o formato JSON do SellFlux
-- ---------------------------------------------------------------------
create or replace function public.tags_do_lote(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object('tag', tag, 'leads', qtd) order by qtd desc)
  into v_res
  from (
    select btrim(t, ' "[]''') as tag, count(*) as qtd
    from jsonb_array_elements(coalesce(p->'linhas','[]'::jsonb)) as l,
         unnest(string_to_array(
           replace(replace(replace(replace(replace(
             lower(coalesce(l->>'tags','')),
             '[', ','), ']', ','), '"', ''), ';', ','), '|', ','), ',')) as t
    where btrim(t, ' "[]''') <> ''
    group by btrim(t, ' "[]''')
  ) x
  where qtd > 0;

  return jsonb_build_object('ok', true, 'tags', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 3. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.importar_tags_padrao(jsonb) from public, anon, authenticated;
grant execute on function public.importar_tags_padrao(jsonb), public.tags_do_lote(jsonb)
  to service_role;
grant all privileges on all tables in schema dash to service_role;
