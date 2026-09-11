-- =====================================================================
-- 90 — O E-MAIL É A CHAVE, O TELEFONE SEMPRE ATUALIZA
--
-- Regra única, decidida com o cliente:
--
--   mesmo e-mail      = mesma pessoa, e o telefone digitado agora
--                       substitui o que estava salvo
--   e-mail diferente  = pessoa diferente, mesmo que o telefone seja
--                       igual
--
-- Isso resolve o caso que aparecia nos testes: o lead voltava, digitava
-- o número certo e a dash mantinha o antigo.
--
-- Para o telefone poder repetir entre cadastros, a restrição de
-- unicidade dele precisa sair — senão dois cadastros com o mesmo número
-- derrubam a captura. O índice continua existindo, só não é mais
-- exclusivo: a busca por telefone segue rápida.
-- =====================================================================

set search_path = dash, public;

-- ---------------------------------------------------------------------
-- 1. TELEFONE DEIXA DE SER ÚNICO
-- ---------------------------------------------------------------------
do $bloco$
declare r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'dash' and c.relname = 'pessoas'
      and con.contype = 'u'
      and pg_get_constraintdef(con.oid) ilike '%telefone%'
  loop
    execute format('alter table dash.pessoas drop constraint %I', r.conname);
    raise notice 'restricao % removida', r.conname;
  end loop;

  -- índices únicos criados fora de constraint
  for r in
    select indexname from pg_indexes
    where schemaname = 'dash' and tablename = 'pessoas'
      and indexdef ilike '%unique%' and indexdef ilike '%telefone%'
  loop
    execute format('drop index if exists dash.%I', r.indexname);
    raise notice 'indice unico % removido', r.indexname;
  end loop;
end $bloco$;

-- busca por telefone continua rápida, agora sem exclusividade
create index if not exists ix_pessoas_telefone on dash.pessoas (telefone);

-- o e-mail passa a ser a chave de verdade
create unique index if not exists ux_pessoas_email
  on dash.pessoas (email) where email is not null;

-- ---------------------------------------------------------------------
-- 2. A CAPTURA SEGUE A REGRA
-- ---------------------------------------------------------------------
create or replace function dash.resolver_pessoa(
  p_email text, p_telefone text, p_nome text default null
) returns uuid language plpgsql as $$
declare e text; t text; pid uuid; t_antigo text;
begin
  e := dash.norm_email(p_email);
  t := dash.norm_phone(p_telefone);

  if e is null and t is null then
    return null;
  end if;

  if e is not null then
    -- o e-mail decide quem é a pessoa
    select id, telefone into pid, t_antigo from dash.pessoas where email = e;

    if pid is null then
      insert into dash.pessoas (nome, email, telefone)
      values (nullif(btrim(coalesce(p_nome,'')), ''), e, t)
      returning id into pid;
      return pid;
    end if;

    -- lead conhecido: o telefone digitado agora vale mais que o salvo
    if t is not null and t_antigo is not null and t_antigo <> t then
      insert into dash.pessoa_identificadores (pessoa_id, tipo, valor)
      values (pid, 'telefone', t_antigo)
      on conflict do nothing;
    end if;

    update dash.pessoas set
      telefone = coalesce(t, telefone),
      nome = coalesce(nullif(btrim(coalesce(p_nome,'')), ''), nome),
      ultimo_contato = now()
    where id = pid;

    return pid;
  end if;

  -- sem e-mail, o telefone é o que resta para identificar
  select id into pid from dash.pessoas
  where telefone = t
  order by criado_em desc
  limit 1;

  if pid is null then
    insert into dash.pessoas (nome, telefone)
    values (nullif(btrim(coalesce(p_nome,'')), ''), t)
    returning id into pid;
  else
    update dash.pessoas set
      nome = coalesce(nullif(btrim(coalesce(p_nome,'')), ''), nome),
      ultimo_contato = now()
    where id = pid;
  end if;

  return pid;
end $$;

-- ---------------------------------------------------------------------
-- 3. O INGEST_LEAD PASSA A USAR ESSA REGRA
-- ---------------------------------------------------------------------
do $bloco$
declare v_def text; v_novo text;
begin
  select pg_get_functiondef(oid) into v_def
  from pg_proc where proname = 'ingest_lead' limit 1;
  if v_def is null then
    raise notice 'ingest_lead nao encontrada';
    return;
  end if;

  v_novo := replace(v_def,
$busca$  if v_email is not null then
    select id into v_pessoa from dash.pessoas where email = v_email limit 1;$busca$,
$novo$  -- a regra vive em resolver_pessoa: e-mail identifica, telefone atualiza
  v_pessoa := dash.resolver_pessoa(p->>'email', p->>'telefone', p->>'nome');

  if false then
    select id into v_pessoa from dash.pessoas where email = v_email limit 1;$novo$);

  -- o bloco antigo de insert/update vira inofensivo
  v_novo := replace(v_novo,
$antigo$    update dash.pessoas set
      nome = coalesce(nullif(btrim(p->>'nome'),''), nome),
      email = coalesce(email, v_email),
      telefone = coalesce(telefone, v_fone)
    where id = v_pessoa;$antigo$,
$novo2$    null;   -- resolver_pessoa ja cuidou disto$novo2$);

  if v_novo = v_def then
    raise warning 'ingest_lead nao pode ser ajustada automaticamente';
  else
    execute v_novo;
    raise notice 'ingest_lead passou a usar resolver_pessoa';
  end if;
end $bloco$;

-- ---------------------------------------------------------------------
-- 4. O UPSERT GERAL SEGUE A MESMA REGRA
--    Usado pelos webhooks de venda e de grupo.
-- ---------------------------------------------------------------------
create or replace function dash.upsert_pessoa(
  p_email text, p_telefone text, p_nome text default null
) returns uuid language plpgsql as $$
declare pid uuid;
begin
  pid := dash.resolver_pessoa(p_email, p_telefone, p_nome);
  if pid is null then
    raise exception 'upsert_pessoa: sem email nem telefone validos (% / %)',
      p_email, p_telefone;
  end if;
  return pid;
end $$;

notify pgrst, 'reload schema';

select 'pronto' as status;
