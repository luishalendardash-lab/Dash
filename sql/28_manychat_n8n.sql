-- =====================================================================
-- 28 — MANYCHAT VIA N8N
--
-- O destino não é o ManyChat direto: é um fluxo do n8n que cria ou
-- atualiza o contato, aplica a tag e aí sim entra no fluxo do ManyChat.
--
-- Consequência prática: o que importa é o nome dos campos bater com o
-- que o workflow do n8n lê. O formato (JSON ou formulário) passa a ser
-- escolhido na tela, porque o n8n aceita os dois e só o workflow sabe
-- qual espera.
-- =====================================================================

set search_path = dash, public;

update dash.integracoes set
  nome = 'ManyChat (via n8n)',
  emoji = '🤖',
  instrucoes = 'A dash manda cada lead capturado para um webhook do n8n, que cria ou atualiza o contato no ManyChat, aplica a tag e coloca a pessoa no fluxo. O envio acontece logo após a captura, antes do quiz — igual ao que o SellFlux fazia antes.',
  passos = '[
    "No n8n, abra o workflow que alimenta o ManyChat e copie a URL do nó Webhook (use a de produção, não a de teste).",
    "Cole a URL no campo abaixo e salve.",
    "Escolha o formato que o seu workflow espera. Na dúvida, deixe JSON: é o mais comum no n8n.",
    "Faça um lead de teste pela landing page e abra as execuções do n8n para ver o que chegou.",
    "Confira se os nomes dos campos batem com o que o workflow lê. A lista do que a dash envia está abaixo."
  ]'::jsonb,
  campos = '[
    {"chave":"webhook","rotulo":"URL do webhook do n8n","tipo":"texto","obrigatorio":true,
     "dica":"https://seu-n8n.com/webhook/...",
     "ajuda":"Use a URL de produção. A de teste só funciona enquanto você está com o editor aberto."}
  ]'::jsonb,
  config = coalesce(config,'{}'::jsonb) || '{"formato":"json"}'::jsonb,
  ajuda_url = 'https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.webhook/'
where slug = 'manychat';

-- ---------------------------------------------------------------------
-- GUARDA O FORMATO ESCOLHIDO
-- ---------------------------------------------------------------------
create or replace function public.salvar_integracao(p jsonb)
returns jsonb language plpgsql security definer
set search_path = dash, public as $$
declare v_slug text; v_novos jsonb;
begin
  v_slug := nullif(p->>'slug','');
  if v_slug is null then
    return jsonb_build_object('ok', false, 'erro', 'informe a integracao');
  end if;
  if not exists (select 1 from dash.integracoes where slug = v_slug) then
    return jsonb_build_object('ok', false, 'erro', 'integracao desconhecida');
  end if;

  -- segredo em branco significa "não mexi nisso", não "apague"
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_novos
  from jsonb_each_text(coalesce(p->'segredos','{}'::jsonb)) as s(k, v)
  where btrim(v) <> '';

  update dash.integracoes set
    ativa = coalesce((p->>'ativa')::boolean, ativa),
    -- config é mesclado, não substituído: salvar a URL não pode apagar
    -- o formato escolhido antes
    config = case when p ? 'config'
                  then coalesce(config,'{}'::jsonb) || coalesce(p->'config','{}'::jsonb)
                  else config end,
    segredos = segredos || coalesce(v_novos, '{}'::jsonb),
    atualizado_em = now()
  where slug = v_slug;

  return jsonb_build_object('ok', true, 'slug', v_slug);
end $$;

grant execute on function public.salvar_integracao(jsonb) to service_role;

select slug, nome, config from dash.integracoes where slug = 'manychat';
