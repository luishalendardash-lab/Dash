-- =====================================================================
-- 82 — QUIZ EM PÁGINA PRÓPRIA
--
-- O quiz acontecia dentro da landing, no lugar do formulário. Na
-- prática o lead fica olhando o resto da página enquanto responde, e
-- abandona no meio.
--
-- Agora, com uma página de quiz configurada, a captura redireciona para
-- lá. Sem configurar, o comportamento continua o de antes.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. GUARDAR O ENDEREÇO
--    p: { lancamento, pagina_quiz }
-- ---------------------------------------------------------------------
create or replace function public.salvar_pagina_quiz(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_lanc uuid; v_url text;
begin
  select id into v_lanc from dash.lancamentos where slug = p->>'lancamento';
  if v_lanc is null then
    return jsonb_build_object('ok', false, 'erro', 'lancamento nao encontrado');
  end if;

  v_url := nullif(btrim(coalesce(p->>'pagina_quiz','')), '');

  -- endereço colado sem esquema quebra o redirecionamento
  if v_url is not null and v_url !~ '^https?://' then
    v_url := 'https://' || v_url;
  end if;

  update dash.lancamentos set
    config = coalesce(config, '{}'::jsonb)
             || jsonb_build_object('pagina_quiz', v_url)
  where id = v_lanc;

  return jsonb_build_object('ok', true, 'pagina_quiz', v_url);
end $$;

-- ---------------------------------------------------------------------
-- 2. O QUIZ ADMIN DEVOLVE O ENDEREÇO
-- ---------------------------------------------------------------------
do $bloco$
declare v_def text;
begin
  select pg_get_functiondef(oid) into v_def
  from pg_proc where proname = 'quiz_admin' limit 1;
  if v_def is null then return; end if;

  if v_def like '%pagina_quiz%' then
    raise notice 'quiz_admin ja devolve pagina_quiz';
    return;
  end if;

  -- a função guarda o grupo numa variável e devolve no jsonb final;
  -- acrescentamos a página logo depois dessa linha
  v_def := replace(v_def,
    '''grupo_url'', v_grupo,',
    '''grupo_url'', v_grupo,
    ''pagina_quiz'', (select config->>''pagina_quiz''
                      from dash.lancamentos where id = v_lanc),');

  execute v_def;
  raise notice 'quiz_admin passou a devolver pagina_quiz';
end $bloco$;

revoke all on function public.salvar_pagina_quiz(jsonb) from public, anon, authenticated;
grant execute on function public.salvar_pagina_quiz(jsonb) to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;
