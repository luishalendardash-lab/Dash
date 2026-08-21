-- =====================================================================
-- 32 — IMPORTAR POR TAGS E RECORRÊNCIA
--
-- Um único CSV com todos os leads e suas tags reconstrói a participação
-- de cada pessoa em todos os lançamentos de uma vez.
--
-- Isso abre uma pergunta que nenhuma plataforma responde sozinha: em
-- quantos lançamentos a pessoa aparece antes de comprar. É o número que
-- diz se vale insistir com quem não comprou no primeiro.
--
-- HONESTIDADE SOBRE A DATA
-- O CSV traz uma data por lead (o cadastro), não uma por participação.
-- Para os lançamentos identificados por tag, usamos a data de captação
-- daquele lançamento como aproximação, e marcamos a inscrição como
-- vinda de tag. Consequência: o gráfico dia a dia dos lançamentos
-- antigos fica achatado. A recorrência, que é o objetivo, fica correta.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. DE ONDE VEIO CADA INSCRIÇÃO
-- ---------------------------------------------------------------------
alter table dash.inscricoes
  add column if not exists data_aproximada boolean not null default false;

comment on column dash.inscricoes.data_aproximada is
  'true quando a participacao foi deduzida de tag: a data e o inicio do lancamento, nao a captura real.';

-- ---------------------------------------------------------------------
-- 2. IMPORTAR UM LEAD COM SUAS TAGS
--    p: {
--      linhas: [ { nome, email, telefone, data, tags, utm_*... } ],
--      mapa_tags: { "fpee-set25": "fpee-2025-09", ... },
--      lancamento_da_data: "fpee-2026-07"   -- onde usar a data real
--    }
-- ---------------------------------------------------------------------
create or replace function public.importar_por_tags(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_linha jsonb; v_mapa jsonb; v_lanc_data text;
  v_email text; v_fone text; v_data timestamptz;
  v_pessoa uuid; v_insc uuid;
  v_tags text; v_tag text; v_slug text; v_lanc uuid; v_quando timestamptz;
  v_pessoas int := 0; v_participacoes int := 0; v_erros int := 0;
  v_sem_tag int := 0; v_primeiro_erro text;
begin
  v_mapa := coalesce(p->'mapa_tags', '{}'::jsonb);
  v_lanc_data := nullif(p->>'lancamento_da_data','');

  if v_mapa = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'erro', 'informe o mapa de tags');
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

      -- percorre as tags da linha
      v_tags := lower(coalesce(v_linha->>'tags', ''));
      if btrim(v_tags) = '' then
        v_sem_tag := v_sem_tag + 1;
      end if;

      for v_tag, v_slug in select key, value from jsonb_each_text(v_mapa)
      loop
        -- a tag aparece na lista? aceita separador por vírgula, ponto e
        -- vírgula ou pipe, e também tag contida em texto corrido
        continue when position(lower(v_tag) in v_tags) = 0;

        select id, coalesce(captacao_inicio, criado_em)
        into v_lanc, v_quando
        from dash.lancamentos where slug = v_slug;
        continue when v_lanc is null;

        -- já existe participação nesse lançamento?
        select id into v_insc from dash.inscricoes
        where pessoa_id = v_pessoa and lancamento_id = v_lanc;
        continue when v_insc is not null;

        insert into dash.inscricoes (
          lancamento_id, pessoa_id, capturado_em, data_aproximada,
          utm_source, utm_medium, utm_campaign, utm_content,
          meta_ad_id, origem_sistema
        ) values (
          v_lanc, v_pessoa,
          -- no lançamento indicado, a data real do CSV; nos outros, o
          -- início da captação daquele lançamento
          case when v_slug = v_lanc_data and v_data is not null
               then v_data else v_quando end,
          not (v_slug = v_lanc_data and v_data is not null),
          nullif(btrim(v_linha->>'utm_source'),''),
          nullif(btrim(v_linha->>'utm_medium'),''),
          nullif(btrim(v_linha->>'utm_campaign'),''),
          nullif(btrim(v_linha->>'utm_content'),''),
          nullif(btrim(v_linha->>'ad_id'),''),
          'importacao'
        )
        returning id into v_insc;

        insert into dash.eventos
          (inscricao_id, pessoa_id, lancamento_id, tipo, fonte, ocorreu_em, dedupe_key)
        values (v_insc, v_pessoa, v_lanc, 'captura', 'importacao',
                coalesce(v_data, v_quando), 'importado:' || v_insc::text)
        on conflict (dedupe_key) do nothing;

        v_participacoes := v_participacoes + 1;
      end loop;

    exception when others then
      v_erros := v_erros + 1;
      v_primeiro_erro := coalesce(v_primeiro_erro, left(SQLERRM, 200));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'pessoas_novas', v_pessoas,
    'participacoes', v_participacoes,
    'linhas_sem_tag', v_sem_tag,
    'erros', v_erros,
    'primeiro_erro', v_primeiro_erro
  );
end $$;

-- ---------------------------------------------------------------------
-- 3. RECORRÊNCIA — quantos lançamentos até comprar
-- ---------------------------------------------------------------------
create or replace function public.dash_recorrencia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare
  v_dist jsonb; v_ate_comprar jsonb; v_resumo jsonb; v_por_lanc jsonb;
begin
  -- quantos lançamentos cada pessoa participou
  with participacao as (
    select pessoa_id, count(distinct lancamento_id) as lancamentos,
           bool_or(comprou) as comprou
    from dash.inscricoes group by pessoa_id
  )
  select jsonb_agg(jsonb_build_object(
    'lancamentos', lancamentos,
    'pessoas', pessoas,
    'compradores', compradores,
    'taxa', case when pessoas > 0
                 then round(100.0 * compradores / pessoas, 1) end
  ) order by lancamentos)
  into v_dist
  from (
    select lancamentos, count(*) as pessoas,
           count(*) filter (where comprou) as compradores
    from participacao group by lancamentos
  ) d;

  -- para quem comprou: em qual participação a compra aconteceu
  with ordenado as (
    select
      i.pessoa_id, i.lancamento_id, i.comprou,
      row_number() over (
        partition by i.pessoa_id
        order by coalesce(l.captacao_inicio, l.criado_em)
      ) as ordem
    from dash.inscricoes i
    join dash.lancamentos l on l.id = i.lancamento_id
  ),
  compra as (
    select pessoa_id, min(ordem) as ordem_compra
    from ordenado where comprou group by pessoa_id
  )
  select jsonb_agg(jsonb_build_object(
    'ordem', ordem_compra, 'pessoas', qtd
  ) order by ordem_compra)
  into v_ate_comprar
  from (select ordem_compra, count(*) as qtd from compra group by ordem_compra) c;

  -- resumo
  with participacao as (
    select pessoa_id, count(distinct lancamento_id) as lancamentos,
           bool_or(comprou) as comprou
    from dash.inscricoes group by pessoa_id
  ),
  ordenado as (
    select i.pessoa_id, i.comprou,
      row_number() over (partition by i.pessoa_id
        order by coalesce(l.captacao_inicio, l.criado_em)) as ordem
    from dash.inscricoes i join dash.lancamentos l on l.id = i.lancamento_id
  )
  select jsonb_build_object(
    'pessoas', (select count(*) from participacao),
    'compradores', (select count(*) from participacao where comprou),
    'media_lancamentos', (select round(avg(lancamentos), 2) from participacao),
    'so_um_lancamento', (select count(*) from participacao where lancamentos = 1),
    'varios_lancamentos', (select count(*) from participacao where lancamentos > 1),
    'media_ate_comprar', (
      select round(avg(ordem), 2) from (
        select min(ordem) as ordem from ordenado where comprou group by pessoa_id
      ) x
    ),
    'compraram_no_primeiro', (
      select count(*) from (
        select min(ordem) as ordem from ordenado where comprou group by pessoa_id
      ) x where ordem = 1
    ),
    'compraram_depois', (
      select count(*) from (
        select min(ordem) as ordem from ordenado where comprou group by pessoa_id
      ) x where ordem > 1
    )
  ) into v_resumo;

  -- por lançamento: quem era novo e quem já vinha de antes
  with primeira as (
    select i.pessoa_id, min(coalesce(l.captacao_inicio, l.criado_em)) as primeiro_em
    from dash.inscricoes i join dash.lancamentos l on l.id = i.lancamento_id
    group by i.pessoa_id
  )
  select jsonb_agg(jsonb_build_object(
    'lancamento', nome,
    'slug', slug,
    'leads', leads,
    'novos', novos,
    'recorrentes', leads - novos,
    'compradores', compradores,
    'compradores_recorrentes', comp_rec
  ) order by inicio)
  into v_por_lanc
  from (
    select l.nome, l.slug, coalesce(l.captacao_inicio, l.criado_em) as inicio,
      count(*) as leads,
      count(*) filter (
        where pr.primeiro_em >= coalesce(l.captacao_inicio, l.criado_em)) as novos,
      count(*) filter (where i.comprou) as compradores,
      count(*) filter (
        where i.comprou
          and pr.primeiro_em < coalesce(l.captacao_inicio, l.criado_em)) as comp_rec
    from dash.inscricoes i
    join dash.lancamentos l on l.id = i.lancamento_id
    join primeira pr on pr.pessoa_id = i.pessoa_id
    group by l.nome, l.slug, l.captacao_inicio, l.criado_em
  ) t;

  return jsonb_build_object(
    'ok', true,
    'resumo', coalesce(v_resumo, '{}'::jsonb),
    'distribuicao', coalesce(v_dist, '[]'::jsonb),
    'ate_comprar', coalesce(v_ate_comprar, '[]'::jsonb),
    'por_lancamento', coalesce(v_por_lanc, '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. TAGS ENCONTRADAS NUM LOTE — ajuda a montar o mapa
-- ---------------------------------------------------------------------
create or replace function public.tags_do_lote(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object('tag', tag, 'leads', qtd) order by qtd desc)
  into v_res
  from (
    select btrim(t) as tag, count(*) as qtd
    from jsonb_array_elements(coalesce(p->'linhas','[]'::jsonb)) as l,
         unnest(string_to_array(
           replace(replace(coalesce(l->>'tags',''), ';', ','), '|', ','), ',')) as t
    where btrim(t) <> ''
    group by btrim(t)
    having count(*) > 0
  ) x;

  return jsonb_build_object('ok', true, 'tags', coalesce(v_res, '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. GRANTS
-- ---------------------------------------------------------------------
revoke all on function public.importar_por_tags(jsonb), public.dash_recorrencia(jsonb),
  public.tags_do_lote(jsonb) from public, anon, authenticated;
grant execute on function public.importar_por_tags(jsonb), public.dash_recorrencia(jsonb),
  public.tags_do_lote(jsonb) to service_role;
grant all privileges on all tables in schema dash to service_role;

select public.dash_recorrencia('{}'::jsonb) -> 'ok' as recorrencia_ok;
