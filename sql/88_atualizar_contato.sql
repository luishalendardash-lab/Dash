-- =====================================================================
-- 88 — TELEFONE NOVO SUBSTITUI O ANTIGO
--
-- O upsert usava coalesce(telefone, t): só preenchia quando o campo
-- estava vazio. Na prática, lead que já existia de um lançamento
-- anterior ficava para sempre com o telefone velho — mesmo digitando o
-- número certo na inscrição nova.
--
-- Isso é grave num negócio de lançamentos recorrentes: boa parte dos
-- leads já está na base, e o WhatsApp é justamente o canal principal.
-- Mensagem indo para número trocado é lead perdido sem aviso nenhum.
--
-- Agora o dado novo vence, e o antigo fica guardado como identificador
-- secundário — assim um evento que chegue com o número velho ainda
-- encontra a pessoa.
-- =====================================================================

set search_path = dash, public;

create or replace function dash.upsert_pessoa(
  p_email text, p_telefone text, p_nome text default null
) returns uuid language plpgsql as $$
declare
  e text; t text; pid uuid; pid_email uuid; pid_fone uuid;
  t_antigo text; e_antigo text;
begin
  e := dash.norm_email(p_email);
  t := dash.norm_phone(p_telefone);
  if e is null and t is null then
    raise exception 'upsert_pessoa: sem email nem telefone válidos (% / %)', p_email, p_telefone;
  end if;

  select id into pid_email from dash.pessoas where email = e and e is not null;
  select id into pid_fone  from dash.pessoas where telefone = t and t is not null;

  pid := coalesce(pid_email, pid_fone);

  if pid is null then
    insert into dash.pessoas (email, telefone, nome)
    values (e, t, nullif(btrim(coalesce(p_nome,'')), ''))
    returning id into pid;
    return pid;
  end if;

  -- e-mail e telefone apontam para pessoas diferentes: guarda o vínculo
  -- sem fundir os cadastros, que exigiria decidir qual sobrevive
  if pid_email is not null and pid_fone is not null and pid_email <> pid_fone then
    insert into dash.pessoa_identificadores (pessoa_id, tipo, valor)
    values (pid_email, 'telefone', t)
    on conflict do nothing;
  end if;

  select telefone, email into t_antigo, e_antigo
  from dash.pessoas where id = pid;

  -- o telefone anterior vira identificador secundário: evento que
  -- chegue com o número velho continua encontrando a pessoa
  if t is not null and t_antigo is not null and t_antigo <> t then
    insert into dash.pessoa_identificadores (pessoa_id, tipo, valor)
    values (pid, 'telefone', t_antigo)
    on conflict do nothing;
  end if;

  if e is not null and e_antigo is not null and e_antigo <> e then
    insert into dash.pessoa_identificadores (pessoa_id, tipo, valor)
    values (pid, 'email', e_antigo)
    on conflict do nothing;
  end if;

  -- O telefone é único na tabela. Se o número novo já pertence a outro
  -- cadastro, atualizar aqui derrubaria a captura inteira com erro de
  -- chave duplicada — e o lead se perderia. Nesse caso mantemos o
  -- telefone atual e registramos o vínculo, para as duas fichas
  -- continuarem alcançáveis.
  if t is not null and pid_fone is not null and pid_fone <> pid then
    insert into dash.pessoa_identificadores (pessoa_id, tipo, valor)
    values (pid, 'telefone', t)
    on conflict do nothing;

    update dash.pessoas set
      email = coalesce(e, email),
      nome  = coalesce(nullif(btrim(coalesce(p_nome,'')), ''), nome),
      ultimo_contato = now()
    where id = pid;

    return pid;
  end if;

  update dash.pessoas set
    -- o dado que a pessoa acabou de digitar vence o que estava salvo
    email    = coalesce(e, email),
    telefone = coalesce(t, telefone),
    nome     = coalesce(nullif(btrim(coalesce(p_nome,'')), ''), nome),
    ultimo_contato = now()
  where id = pid;

  return pid;

exception
  -- rede de segurança: qualquer choque de unicidade não pode fazer o
  -- lead se perder. Guardamos o que dá e devolvemos a pessoa.
  when unique_violation then
    update dash.pessoas set
      nome = coalesce(nullif(btrim(coalesce(p_nome,'')), ''), nome),
      ultimo_contato = now()
    where id = pid;
    return pid;
end $$;

-- ---------------------------------------------------------------------
-- A BUSCA POR EVENTO OLHA TAMBÉM OS IDENTIFICADORES ANTIGOS
--
-- Sem isso, trocar o telefone quebraria o casamento de quem entrou no
-- grupo com o número anterior.
-- ---------------------------------------------------------------------
create or replace function dash.achar_pessoa(p_email text, p_telefone text)
returns uuid language plpgsql stable as $$
declare e text; t text; pid uuid;
begin
  e := dash.norm_email(p_email);
  t := dash.norm_phone(p_telefone);

  if t is not null then
    select id into pid from dash.pessoas where telefone = t;
    if pid is not null then return pid; end if;
  end if;

  if e is not null then
    select id into pid from dash.pessoas where email = e;
    if pid is not null then return pid; end if;
  end if;

  -- telefone ou e-mail que a pessoa usou antes
  if t is not null then
    select pessoa_id into pid from dash.pessoa_identificadores
    where tipo = 'telefone' and valor = t limit 1;
    if pid is not null then return pid; end if;
  end if;

  if e is not null then
    select pessoa_id into pid from dash.pessoa_identificadores
    where tipo = 'email' and valor = e limit 1;
  end if;

  return pid;
end $$;

grant execute on function dash.achar_pessoa(text, text) to service_role;

notify pgrst, 'reload schema';

select 'pronto' as status;

-- =====================================================================
-- CORRIGIR OS LEADS QUE FICARAM COM O TELEFONE ANTIGO
--
-- Quem se inscreveu de novo enquanto o coalesce estava lá ficou com o
-- número velho. Não dá para adivinhar o certo — mas dá para listar
-- quem está nessa situação, para conferir caso a caso.
-- =====================================================================

create or replace function public.telefones_suspeitos(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'nome', nome, 'email', email, 'telefone', telefone,
    'cadastrado_em', criado_em, 'inscricoes', n,
    'ultima_inscricao', ultima
  ) order by ultima desc)
  into v_res
  from (
    select p2.nome, p2.email, p2.telefone, p2.criado_em,
           count(i.id) as n,
           max(i.capturado_em) as ultima
    from dash.pessoas p2
    join dash.inscricoes i on i.pessoa_id = p2.id
    where
      -- cadastro antigo com inscrição recente: é quem pode ter digitado
      -- um telefone novo que foi descartado
      p2.criado_em < now() - interval '60 days'
      and exists (select 1 from dash.inscricoes i2
                  where i2.pessoa_id = p2.id
                    and i2.capturado_em > now() - interval '60 days')
      -- número repetido é sinal de dado de teste
      and (p2.telefone ~ '(\d)\1{6,}' or p2.telefone is null)
    group by p2.nome, p2.email, p2.telefone, p2.criado_em
    limit 100
  ) t;

  return jsonb_build_object('ok', true, 'pessoas', coalesce(v_res, '[]'::jsonb));
end $$;

revoke all on function public.telefones_suspeitos(jsonb) from public, anon, authenticated;
grant execute on function public.telefones_suspeitos(jsonb) to service_role;

select jsonb_pretty(public.telefones_suspeitos('{}'::jsonb));
