-- =====================================================================
-- 36 — PLANILHAS DE CAPTURA
--
-- As planilhas do formulário antigo trazem coisas que o export do
-- SellFlux não tem, e em duas versões que se completam:
--
--   LEADS SIMPLES  data real, campanha/conjunto/anúncio e os IDs
--                  numéricos do Meta — o que permite ligar com os
--                  dados de gasto da API
--   MESTRE         as respostas do quiz, incluindo a formação, que é
--                  o que define quem é engenheiro
--
-- Uma pegadinha do formulário: os nomes das UTMs estão trocados em
-- relação ao padrão. utm_source guarda a campanha, utm_medium o
-- conjunto e utm_campaign o anúncio. O importador aceita o mapeamento
-- na ordem certa, então isso é resolvido na tela.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. RESPOSTAS DE QUIZ VINDAS DE PLANILHA
-- ---------------------------------------------------------------------
create table if not exists dash.quiz_respostas_livres (
  id            uuid primary key default gen_random_uuid(),
  inscricao_id  uuid references dash.inscricoes(id) on delete cascade,
  pergunta      text not null,
  resposta      text,
  criado_em     timestamptz not null default now(),
  unique (inscricao_id, pergunta)
);

alter table dash.quiz_respostas_livres enable row level security;
create index if not exists ix_qrl_insc on dash.quiz_respostas_livres (inscricao_id);

-- ---------------------------------------------------------------------
-- 2. IMPORTAR CAPTURA COMPLETA
--    p: {
--      lancamento, linhas: [{
--        nome, email, telefone, data,
--        campanha, conjunto, anuncio,        -- nomes
--        campanha_id, conjunto_id, anuncio_id, -- ids do Meta
--        fbclid,
--        respostas: { "pergunta": "resposta", ... },
--        formacao                              -- define engenheiro
--      }],
--      valores_engenheiro: 'engenheiro eletricista|engenheiro de outra'
--    }
-- ---------------------------------------------------------------------
create or replace function public.importar_captura(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_lanc uuid; v_linha jsonb; v_resp jsonb;
  v_email text; v_fone text; v_data timestamptz;
  v_pessoa uuid; v_insc uuid; v_formacao text; v_eng boolean;
  v_padrao_eng text; v_chave text; v_valor text;
  v_novos int := 0; v_completados int := 0; v_erros int := 0;
  v_com_anuncio int := 0; v_engs int := 0; v_respostas int := 0;
  v_primeiro_erro text; v_existia boolean;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  v_padrao_eng := lower(coalesce(nullif(p->>'valores_engenheiro',''),
                                 'engenheiro eletricista'));

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

      -- formação decide engenheiro
      v_formacao := lower(btrim(coalesce(v_linha->>'formacao', '')));
      v_eng := v_formacao <> '' and v_formacao ~ v_padrao_eng;

      -- pessoa
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
      v_existia := v_insc is not null;

      if v_insc is null then
        insert into dash.inscricoes (
          lancamento_id, pessoa_id, capturado_em, data_aproximada,
          utm_source, utm_medium, utm_campaign, utm_content,
          meta_campaign_id, meta_adset_id, meta_ad_id, fbclid,
          origem_sistema, engenheiro, fez_quiz, comprou
        ) values (
          v_lanc, v_pessoa,
          coalesce(v_data, now()), v_data is null,
          nullif(btrim(v_linha->>'campanha'),''),
          nullif(btrim(v_linha->>'conjunto'),''),
          -- utm_campaign guarda o nome da campanha na nossa convenção;
          -- o nome do anúncio vai em utm_content
          nullif(btrim(v_linha->>'campanha'),''),
          nullif(btrim(v_linha->>'anuncio'),''),
          nullif(btrim(v_linha->>'campanha_id'),''),
          nullif(btrim(v_linha->>'conjunto_id'),''),
          nullif(btrim(v_linha->>'anuncio_id'),''),
          nullif(btrim(v_linha->>'fbclid'),''),
          'importacao',
          v_eng,
          coalesce(jsonb_typeof(v_linha->'respostas') = 'object', false) is true,
          false
        )
        returning id into v_insc;
        v_novos := v_novos + 1;
      else
        update dash.inscricoes set
          utm_source   = coalesce(utm_source,   nullif(btrim(v_linha->>'campanha'),'')),
          utm_medium   = coalesce(utm_medium,   nullif(btrim(v_linha->>'conjunto'),'')),
          utm_campaign = coalesce(utm_campaign, nullif(btrim(v_linha->>'campanha'),'')),
          utm_content  = coalesce(utm_content,  nullif(btrim(v_linha->>'anuncio'),'')),
          meta_campaign_id = coalesce(meta_campaign_id, nullif(btrim(v_linha->>'campanha_id'),'')),
          meta_adset_id = coalesce(meta_adset_id, nullif(btrim(v_linha->>'conjunto_id'),'')),
          meta_ad_id   = coalesce(meta_ad_id,   nullif(btrim(v_linha->>'anuncio_id'),'')),
          fbclid       = coalesce(fbclid,       nullif(btrim(v_linha->>'fbclid'),'')),
          -- a formação só sobrescreve quando a planilha traz o dado
          engenheiro   = case when v_formacao <> '' then v_eng else engenheiro end,
          fez_quiz     = coalesce(fez_quiz, false)
                         or coalesce(jsonb_typeof(v_linha->'respostas') = 'object', false),
          -- data real vence a aproximada
          capturado_em = case when data_aproximada and v_data is not null
                              then v_data else capturado_em end,
          data_aproximada = case when data_aproximada and v_data is not null
                                 then false else data_aproximada end,
          atualizado_em = now()
        where id = v_insc;
        v_completados := v_completados + 1;
      end if;

      if nullif(btrim(v_linha->>'anuncio_id'),'') is not null
         or nullif(btrim(v_linha->>'anuncio'),'') is not null then
        v_com_anuncio := v_com_anuncio + 1;
      end if;
      if v_eng then v_engs := v_engs + 1; end if;

      -- respostas do quiz
      if jsonb_typeof(v_linha->'respostas') = 'object' then
        for v_chave, v_valor in select key, value from jsonb_each_text(v_linha->'respostas')
        loop
          continue when btrim(coalesce(v_valor,'')) = '';
          insert into dash.quiz_respostas_livres (inscricao_id, pergunta, resposta)
          values (v_insc, v_chave, btrim(v_valor))
          on conflict (inscricao_id, pergunta) do update set resposta = excluded.resposta;
          v_respostas := v_respostas + 1;
        end loop;
      end if;

      if not v_existia then
        insert into dash.eventos
          (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key)
        values (v_insc, v_pessoa, v_lanc, 'captura', 'importacao',
                coalesce(v_data, now()), 'importado:' || v_insc::text)
        on conflict (dedupe_key) do nothing;
      end if;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'novos', v_novos, 'completados', v_completados,
    'com_anuncio', v_com_anuncio, 'engenheiros', v_engs,
    'respostas_quiz', v_respostas,
    'erros', v_erros, 'primeiro_erro', v_primeiro_erro
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. RESPOSTAS NA FICHA DO LEAD
-- ---------------------------------------------------------------------
create or replace function public.respostas_do_lead(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object('pergunta', pergunta, 'resposta', resposta)
                   order by pergunta)
  into v_res
  from dash.quiz_respostas_livres
  where inscricao_id = (p->>'inscricao_id')::uuid;

  return jsonb_build_object('ok', true, 'respostas', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 4. O QUE AS PLANILHAS REVELAM
--    Distribuição das respostas por lançamento — serve para comparar
--    perfil de lead entre lançamentos.
-- ---------------------------------------------------------------------
create or replace function public.perfil_respostas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_res jsonb;
begin
  if p ? 'lancamento' and nullif(p->>'lancamento','') is not null then
    select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  end if;

  select jsonb_agg(x order by (x->>'pergunta')) into v_res
  from (
    select jsonb_build_object(
      'pergunta', r.pergunta,
      'respostas', (
        select jsonb_agg(jsonb_build_object('resposta', r2.resposta, 'leads', c)
                         order by c desc)
        from (
          select resposta, count(*) as c
          from dash.quiz_respostas_livres q2
          join dash.inscricoes i2 on i2.id = q2.inscricao_id
          where q2.pergunta = r.pergunta
            and (v_lanc is null or i2.lancamento_id = v_lanc)
          group by resposta
          order by count(*) desc
          limit 10
        ) r2
      )
    ) as x
    from dash.quiz_respostas_livres r
    join dash.inscricoes i on i.id = r.inscricao_id
    where (v_lanc is null or i.lancamento_id = v_lanc)
    group by r.pergunta
  ) t;

  return jsonb_build_object('ok', true, 'perguntas', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.importar_captura(jsonb), public.respostas_do_lead(jsonb),
  public.perfil_respostas(jsonb) from public, anon, authenticated;
grant execute on function public.importar_captura(jsonb), public.respostas_do_lead(jsonb),
  public.perfil_respostas(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;
