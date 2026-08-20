-- =====================================================================
-- 29 — WEBHOOK POR LANÇAMENTO
--
-- No SendFlow o webhook é ligado a uma ou mais campanhas de grupo. Como
-- cada lançamento tem seus próprios grupos, é preciso uma conexão nova a
-- cada mês.
--
-- A solução não exige nada de novo no banco: a URL do webhook passa a
-- aceitar o lançamento no fim (?l=slug). Cada conexão no SendFlow aponta
-- para a URL do seu lançamento, e a dash sabe onde colocar cada entrada
-- de grupo.
--
-- Vale para qualquer integração, não só o SendFlow. Sem o parâmetro, o
-- webhook continua caindo no lançamento padrão — nada quebra.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  instrucoes = 'No SendFlow o webhook é ligado às campanhas de grupo. Como cada lançamento tem grupos próprios, crie uma conexão nova a cada lançamento, usando a URL abaixo — ela já vem com o lançamento atual no fim. É isso que faz a entrada no grupo cair no lançamento certo.',
  passos = '[
    "No SendFlow, abra a configuração de webhooks e crie uma conexão nova.",
    "Cole a URL abaixo. Repare que ela termina com o lançamento atual — é o que amarra os dados a ele.",
    "Selecione as campanhas de grupo deste lançamento, e só elas.",
    "Marque os eventos de entrada e saída de participante.",
    "Salve e ative.",
    "No próximo lançamento, repita: a dash gera uma URL nova com o lançamento novo, e você seleciona os grupos daquele mês."
  ]'::jsonb,
  campos = '[]'::jsonb
where slug = 'sendflow';

-- ---------------------------------------------------------------------
-- ONDE CADA ENTRADA DE GRUPO FOI PARAR
-- Se as conexões estiverem trocadas, isso mostra na hora.
-- ---------------------------------------------------------------------
create or replace function public.conferir_grupos(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'lancamento', l.nome,
    'slug', l.slug,
    'status', l.status,
    'entradas', (
      select count(*) from dash.eventos e
      join dash.inscricoes i on i.id = e.inscricao_id
      where i.lancamento_id = l.id and e.tipo = 'grupo_entrou'
    ),
    'ultima_entrada', (
      select max(e.ocorreu_em) from dash.eventos e
      join dash.inscricoes i on i.id = e.inscricao_id
      where i.lancamento_id = l.id and e.tipo = 'grupo_entrou'
    )
  ) order by l.criado_em desc)
  into v_res
  from dash.lancamentos l;

  return jsonb_build_object('ok', true, 'lancamentos', coalesce(v_res, '[]'::jsonb));
end $$;

revoke all on function public.conferir_grupos(jsonb) from public, anon, authenticated;
grant execute on function public.conferir_grupos(jsonb) to service_role;

select public.conferir_grupos('{}'::jsonb);
