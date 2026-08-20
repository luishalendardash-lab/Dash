/**
 * DASH DE LANÇAMENTO — WORKER ÚNICO
 * Arquivo único na raiz do repositório. Faz a ingestão E serve a dash.
 *
 * ---- ENTRADA DE DADOS ----
 *   POST /captura              formulário próprio -> banco -> SellFlux + ManyChat
 *   POST /w/:fonte/:secret     webhook (hotmart, sellflux, manychat, sendflow, quiz)
 *   GET  /r/grupo/:secret      redirect rastreado para o grupo de WhatsApp
 *   GET  /debug/ultimos        últimos payloads crus
 *   POST /debug/reprocessar    reprocessa o que falhou
 *
 * ---- DASH (login por e-mail e senha) ----
 *   POST /api/login            { email, senha } -> { token, refresh }
 *   POST /api/refresh          { refresh }      -> { token, refresh }
 *   GET  /api/lancamentos
 *   GET  /api/home?lancamento=&periodo=&dias=
 *   GET  /api/leads?lancamento=&etapa=&busca=&pagina=
 *   GET  /api/lead/:id
 *
 *   GET  /health               diagnóstico
 */

interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  SUPABASE_ANON_KEY: string;     // valida o login da dash
  WEBHOOK_SECRET: string;
  DEBUG_TOKEN: string;
  LANCAMENTO_PADRAO?: string;
  SELLFLUX_ENDPOINT?: string;
  SELLFLUX_TOKEN?: string;
  MANYCHAT_WEBHOOK?: string;
  META_TOKEN?: string;           // token de usuário do sistema (Business Manager)
  META_API_VERSAO?: string;      // ex: v25.0
}

const FONTES_VALIDAS = ['sellflux', 'quiz', 'sendflow', 'manychat', 'hotmart', 'teste'];

// =====================================================================
// CLIENTE SUPABASE
// =====================================================================
class Supabase {
  constructor(private url: string, private key: string) {}

  private headers(schema?: string, extra: Record<string, string> = {}) {
    const h: Record<string, string> = {
      apikey: this.key,
      Authorization: `Bearer ${this.key}`,
      'Content-Type': 'application/json',
      ...extra,
    };
    if (schema && schema !== 'public') {
      h['Accept-Profile'] = schema;
      h['Content-Profile'] = schema;
    }
    return h;
  }

  async rpc(fn: string, args: Record<string, any>): Promise<any> {
    const r = await fetch(`${this.url}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: this.headers(), body: JSON.stringify(args),
    });
    const texto = await r.text();
    if (!r.ok) throw new Error(`rpc ${fn} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return texto; }
  }

  async insert(tabela: string, dados: any, schema = 'dash'): Promise<any> {
    const r = await fetch(`${this.url}/rest/v1/${tabela}`, {
      method: 'POST',
      headers: this.headers(schema, { Prefer: 'return=representation' }),
      body: JSON.stringify(dados),
    });
    const texto = await r.text();
    if (!r.ok) throw new Error(`insert ${tabela} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return null; }
  }

  async update(tabela: string, filtros: Record<string, string>, dados: any, schema = 'dash') {
    const qs = new URLSearchParams(filtros).toString();
    const r = await fetch(`${this.url}/rest/v1/${tabela}?${qs}`, {
      method: 'PATCH',
      headers: this.headers(schema, { Prefer: 'return=minimal' }),
      body: JSON.stringify(dados),
    });
    if (!r.ok) throw new Error(`update ${tabela} ${r.status}`);
    return true;
  }

  async select(tabela: string, filtros: Record<string, string> = {}, schema = 'dash'): Promise<any[]> {
    const qs = new URLSearchParams(filtros).toString();
    const r = await fetch(`${this.url}/rest/v1/${tabela}?${qs}`, { headers: this.headers(schema) });
    const texto = await r.text();
    if (!r.ok) throw new Error(`select ${tabela} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return []; }
  }
}

// =====================================================================
// HELPERS
// =====================================================================
function jsonResponse(dados: any, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(dados, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...extraHeaders },
  });
}

function corsHeaders(origem: string | null): Record<string, string> {
  // Liberado para qualquer origem. Quem protege a dash é o login, e as
  // rotas de webhook exigem o segredo na URL. Manter uma lista aqui só
  // criava quebra silenciosa toda vez que um domínio mudava.
  return {
    'Access-Control-Allow-Origin': origem || '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '600',
    'Vary': 'Origin',
  };
}

async function safeJson(req: Request): Promise<any> {
  const tipo = (req.headers.get('content-type') || '').toLowerCase();
  const texto = await req.text();
  if (!texto) return {};
  if (tipo.includes('form-urlencoded')) {
    const obj: Record<string, any> = {};
    new URLSearchParams(texto).forEach((v, k) => {
      try { obj[k] = JSON.parse(v); } catch { obj[k] = v; }
    });
    return obj;
  }
  try { return JSON.parse(texto); } catch { return { _texto_bruto: texto }; }
}

// =====================================================================
// PARSERS TOLERANTES
// =====================================================================
function achar(obj: any, nomes: string[], profundidade = 6): any {
  if (!obj || typeof obj !== 'object' || profundidade < 0) return undefined;
  const alvos = nomes.map((n) => n.toLowerCase().replace(/[^a-z0-9]/g, ''));
  for (const [k, v] of Object.entries(obj)) {
    const chave = k.toLowerCase().replace(/[^a-z0-9]/g, '');
    if (alvos.includes(chave) && v !== null && v !== '' && typeof v !== 'object') return v;
  }
  for (const v of Object.values(obj)) {
    if (v && typeof v === 'object') {
      const achado = achar(v, nomes, profundidade - 1);
      if (achado !== undefined) return achado;
    }
  }
  return undefined;
}

const s = (v: any): string | undefined => {
  if (v === null || v === undefined) return undefined;
  const t = String(v).trim();
  return t === '' ? undefined : t;
};

const EMAIL_KEYS = ['email', 'e_mail', 'mail', 'lead_email', 'buyer_email', 'contact_email'];
const FONE_KEYS = ['telefone', 'phone', 'whatsapp', 'celular', 'fone', 'phone_number',
                   'mobile', 'lead_phone', 'buyer_phone', 'wa_id', 'numero'];
const NOME_KEYS = ['nome', 'name', 'full_name', 'first_name', 'lead_name', 'buyer_name', 'nome_completo'];

function extrairUtm(body: any) {
  const utm: any = {
    source: s(achar(body, ['utm_source', 'utmsource', 'source', 'origem_utm'])),
    medium: s(achar(body, ['utm_medium', 'utmmedium', 'medium'])),
    campaign: s(achar(body, ['utm_campaign', 'utmcampaign', 'campaign', 'campanha'])),
    content: s(achar(body, ['utm_content', 'utmcontent', 'content', 'criativo'])),
    term: s(achar(body, ['utm_term', 'utmterm', 'term'])),
  };
  const meta: any = {
    campaign_id: s(achar(body, ['cid', 'campaign_id', 'campaignid'])),
    adset_id: s(achar(body, ['aid', 'adset_id', 'adsetid'])),
    ad_id: s(achar(body, ['adid', 'ad_id', 'anuncio_id'])),
  };
  let fbclid = s(achar(body, ['fbclid', 'fbc']));
  const landing = s(achar(body, ['pagina_origem', 'url', 'page_url', 'landing_url', 'pagina', 'link']));

  if (landing && landing.includes('?')) {
    try {
      const qs = new URL(landing.startsWith('http') ? landing : `https://x.com${landing}`).searchParams;
      utm.source ||= s(qs.get('utm_source'));
      utm.medium ||= s(qs.get('utm_medium'));
      utm.campaign ||= s(qs.get('utm_campaign'));
      utm.content ||= s(qs.get('utm_content'));
      utm.term ||= s(qs.get('utm_term'));
      meta.campaign_id ||= s(qs.get('cid')) || s(qs.get('campaign_id'));
      meta.adset_id ||= s(qs.get('aid')) || s(qs.get('adset_id'));
      meta.ad_id ||= s(qs.get('adid')) || s(qs.get('ad_id'));
      fbclid ||= s(qs.get('fbclid'));
    } catch {}
  }
  return { utm, meta, fbclid, landing_url: landing };
}

function parseSellflux(body: any, lp?: string, rawId?: number | null) {
  const { utm, meta, fbclid, landing_url } = extrairUtm(body);
  const idOrigem = s(achar(body, ['id', 'lead_id', 'leadid', 'uuid', 'contact_id']));
  return {
    lancamento: s(achar(body, ['lancamento', 'launch', 'lanc'])) || lp,
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    origem: 'sellflux',
    sellflux_lead_id: idOrigem,
    capturado_em: s(achar(body, ['created_at', 'data', 'date', 'timestamp'])),
    utm, meta, fbclid, landing_url,
    dedupe_key: idOrigem ? `sellflux:${idOrigem}` : rawId ? `raw:${rawId}` : undefined,
    payload: body,
  };
}

function parseQuiz(body: any, lp?: string, rawId?: number | null) {
  let respostas = achar(body, ['respostas', 'answers', 'resultados']);
  if (!Array.isArray(respostas)) {
    respostas = Array.isArray(body?.respostas) ? body.respostas
              : Array.isArray(body?.answers) ? body.answers : [];
  }
  const normalizadas = (respostas as any[]).map((r: any) => ({
    chave: s(r?.chave ?? r?.key ?? r?.question_id ?? r?.pergunta) || 'sem_chave',
    valor: s(r?.valor ?? r?.value ?? r?.answer ?? r?.resposta),
    label: s(r?.label ?? r?.texto ?? r?.answer_label),
    pontos: Number(r?.pontos ?? r?.points ?? r?.score ?? 0) || 0,
  }));
  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lp,
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    fonte: 'quiz',
    score: achar(body, ['score', 'pontuacao', 'lead_score']),
    tier: s(achar(body, ['tier', 'classificacao', 'nivel'])),
    respostas: normalizadas,
    dedupe_key: rawId ? `quiz:raw:${rawId}` : undefined,
  };
}

function parseSendflow(body: any, lp?: string, rawId?: number | null) {
  const evento = (s(achar(body, ['event', 'evento', 'tipo', 'action', 'status'])) || '').toLowerCase();
  let tipo = 'grupo_entrou';
  if (/(sai|left|remov|exit|out)/.test(evento)) tipo = 'grupo_saiu';
  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lp,
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    tipo, fonte: 'sendflow',
    ocorreu_em: s(achar(body, ['created_at', 'timestamp', 'data', 'date'])),
    payload: {
      grupo: s(achar(body, ['grupo', 'group', 'group_name', 'nome_grupo'])),
      evento_original: evento, raw: body,
    },
    dedupe_key: rawId ? `sendflow:raw:${rawId}` : undefined,
  };
}

function parseManychat(body: any, lp?: string, rawId?: number | null) {
  const evento = (s(achar(body, ['event', 'evento', 'type', 'tipo'])) || '').toLowerCase();
  const tipo = /(reply|resposta|received|inbound|respondeu)/.test(evento)
    ? 'whats_respondido' : 'whats_enviado';
  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lp,
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    tipo, fonte: 'manychat',
    ocorreu_em: s(achar(body, ['timestamp', 'created_at', 'data'])),
    payload: {
      manychat_id: s(achar(body, ['subscriber_id', 'contact_id', 'id'])),
      fluxo: s(achar(body, ['flow', 'fluxo', 'campaign', 'tag'])),
      raw: body,
    },
    dedupe_key: rawId ? `manychat:raw:${rawId}` : undefined,
  };
}

const STATUS_HOTMART: Record<string, string> = {
  approved: 'aprovada', complete: 'aprovada',
  purchase_approved: 'aprovada', purchase_complete: 'aprovada',
  waiting_payment: 'pendente', purchase_billet_printed: 'pendente',
  printed_billet: 'pendente', purchase_protest: 'pendente',
  canceled: 'cancelada', purchase_canceled: 'cancelada', expired: 'cancelada',
  refunded: 'reembolsada', purchase_refunded: 'reembolsada',
  chargeback: 'chargeback', purchase_chargeback: 'chargeback',
};

function parseHotmart(body: any, lp?: string, rawId?: number | null) {
  const bruto = (s(achar(body, ['status', 'event', 'evento', 'transaction_status'])) || '').toLowerCase();
  const valor = Number(achar(body, ['full_price', 'price', 'valor', 'total', 'amount']) ?? 0) || 0;
  const metodoBruto = (s(achar(body, ['payment_type', 'metodo', 'payment_method'])) || '').toLowerCase();
  const metodo = /pix/.test(metodoBruto) ? 'pix'
               : /(billet|boleto)/.test(metodoBruto) ? 'boleto'
               : /(credit|card|cartao)/.test(metodoBruto) ? 'cartao'
               : metodoBruto || undefined;
  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lp,
    plataforma: 'hotmart',
    transacao_id: s(achar(body, ['transaction', 'transaction_id', 'transacao', 'order_id']))
                  || (rawId ? `raw-${rawId}` : `sem-id-${Date.now()}`),
    produto: s(achar(body, ['product_name', 'prod_name', 'produto', 'name'])),
    oferta: s(achar(body, ['offer', 'oferta', 'off', 'offer_code'])),
    status: STATUS_HOTMART[bruto] || 'pendente',
    metodo,
    parcelas: s(achar(body, ['installments_number', 'parcelas', 'installments'])),
    valor_bruto: valor,
    valor_liquido: Number(achar(body, ['producer_value', 'commission']) ?? 0) || 0,
    moeda: s(achar(body, ['currency', 'currency_code', 'moeda'])) || 'BRL',
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    src: s(achar(body, ['src', 'sck', 'source'])),
    ocorreu_em: s(achar(body, ['purchase_date', 'order_date', 'creation_date', 'timestamp'])),
    raw: body,
  };
}

// =====================================================================
// REPASSE AO SELLFLUX (server-side, depois de gravar no banco)
// =====================================================================
async function repassarSellflux(dados: any, env: Env, db: Supabase, pessoaId?: string) {
  if (!env.SELLFLUX_ENDPOINT) return;

  const corpo = new URLSearchParams();
  corpo.set('name', dados.nome || '');
  corpo.set('email', dados.email || '');
  corpo.set('phone', dados.telefone || '');
  if (dados.utm?.source)   corpo.set('utm_source', dados.utm.source);
  if (dados.utm?.medium)   corpo.set('utm_medium', dados.utm.medium);
  if (dados.utm?.campaign) corpo.set('utm_campaign', dados.utm.campaign);
  if (dados.utm?.content)  corpo.set('utm_content', dados.utm.content);
  if (dados.meta?.ad_id)   corpo.set('adid', dados.meta.ad_id);
  if (dados.landing_url)   corpo.set('url', dados.landing_url);

  const headers: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded',
  };
  if (env.SELLFLUX_TOKEN) headers['Authorization'] = `Bearer ${env.SELLFLUX_TOKEN}`;

  try {
    const r = await fetch(env.SELLFLUX_ENDPOINT, { method: 'POST', headers, body: corpo });
    if (!r.ok) throw new Error(`sellflux ${r.status}: ${(await r.text()).slice(0, 200)}`);
  } catch (e: any) {
    // o lead já está no banco; registra a falha para reenvio
    await db.insert('webhooks_raw', {
      fonte: 'sellflux_saida_falhou',
      body: { dados, pessoa_id: pessoaId },
      processado: false,
      erro: String(e?.message || e).slice(0, 500),
    }, 'dash').catch(() => {});
  }
}

// =====================================================================
// PROCESSAMENTO DE WEBHOOK DE ENTRADA
// =====================================================================
async function processar(fonte: string, body: any, rawId: number | null, db: Supabase, env: Env) {
  try {
    let resultado: any;
    const lp = env.LANCAMENTO_PADRAO;
    switch (fonte) {
      case 'sellflux':
      case 'teste':
        resultado = await db.rpc('ingest_lead', { p: parseSellflux(body, lp, rawId) }); break;
      case 'quiz':
        resultado = await db.rpc('ingest_quiz', { p: parseQuiz(body, lp, rawId) }); break;
      case 'sendflow':
        resultado = await db.rpc('ingest_evento', { p: parseSendflow(body, lp, rawId) }); break;
      case 'manychat':
        resultado = await db.rpc('ingest_evento', { p: parseManychat(body, lp, rawId) }); break;
      case 'hotmart':
        resultado = await db.rpc('ingest_venda', { p: parseHotmart(body, lp, rawId) }); break;
      default:
        throw new Error(`sem parser para a fonte "${fonte}"`);
    }
    if (rawId) {
      const deuCerto = resultado?.ok !== false;
      await db.update('webhooks_raw', { id: `eq.${rawId}` }, {
        processado: deuCerto,
        erro: deuCerto ? null : String(resultado?.erro || 'rpc retornou ok:false'),
      }, 'dash');
    }
  } catch (e: any) {
    if (rawId) {
      await db.update('webhooks_raw', { id: `eq.${rawId}` }, {
        processado: false, erro: String(e?.message || e).slice(0, 500),
      }, 'dash').catch(() => {});
    }
  }
}

// =====================================================================
// META ADS
// Busca campanhas/conjuntos/anúncios e as métricas diárias e grava no
// banco. Roda por cron e também sob demanda em /sync/meta.
// =====================================================================
const META_VERSAO_PADRAO = 'v25.0';

async function metaGet(caminho: string, params: Record<string, string>, env: Env): Promise<any> {
  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  const qs = new URLSearchParams({ ...params, access_token: env.META_TOKEN || '' });
  const r = await fetch(`https://graph.facebook.com/${versao}/${caminho}?${qs}`);
  const d: any = await r.json().catch(() => ({}));
  if (!r.ok || d.error) throw new Error(`meta ${caminho}: ${d?.error?.message || r.status}`);
  return d;
}

/** Percorre a paginação do Meta até acabar (ou até o teto de páginas). */
async function metaTudo(caminho: string, params: Record<string, string>, env: Env, teto = 12) {
  let dados: any[] = [];
  let d = await metaGet(caminho, { ...params, limit: '200' }, env);
  dados = dados.concat(d.data || []);
  let paginas = 1;
  while (d?.paging?.next && paginas < teto) {
    const r = await fetch(d.paging.next);
    d = await r.json().catch(() => ({}));
    if (d?.error) break;
    dados = dados.concat(d.data || []);
    paginas++;
  }
  // truncou: existe mais dado do que o teto permitiu buscar
  (dados as any).truncado = paginas >= teto && !!d?.paging?.next;
  return dados;
}

/** Sincroniza UMA conta de anúncios. */
async function sincronizarConta(
  conta: string, slug: string, cfg: any, codigo: string, dias: number, db: Supabase, env: Env
) {
  const filtroIds: string[] = Array.isArray(cfg.meta_campanhas) ? cfg.meta_campanhas : [];
  // o código do lançamento é o filtro padrão; meta_prefixo só sobrescreve
  const prefixo: string = cfg.meta_prefixo || codigo || '';

  // ---- campanhas
  // Pede ao Meta só o que contém o código, em vez de baixar a conta inteira.
  const paramsCampanha: Record<string, string> = { fields: 'id,name,status,objective' };
  if (prefixo && !filtroIds.length) {
    paramsCampanha.filtering = JSON.stringify([
      { field: 'campaign.name', operator: 'CONTAIN', value: prefixo },
    ]);
  }

  let campanhas = await metaTudo(`${conta}/campaigns`, paramsCampanha, env);

  if (filtroIds.length) {
    campanhas = campanhas.filter((c: any) => filtroIds.includes(c.id));
  } else if (prefixo) {
    // CONTAIN acha no meio do nome; aqui exigimos que seja o início mesmo
    campanhas = campanhas.filter((c: any) =>
      (c.name || '').trim().toUpperCase().startsWith(prefixo.toUpperCase()));
  }

  if (!campanhas.length) {
    return { conta, campanhas: 0, conjuntos: 0, anuncios: 0, dias_metricas: 0,
             filtro: prefixo || 'nenhum',
             aviso: `nenhuma campanha começando com "${prefixo}" nesta conta` };
  }
  const idsCampanha = campanhas.map((c: any) => c.id);

  // ---- conjuntos e anúncios
  // Com filtro, busca POR CAMPANHA: evita varrer a conta inteira e some
  // o risco de truncar na paginação (contas antigas têm milhares de ads).
  let conjuntos: any[] = [];
  let anuncios: any[] = [];

  if (filtroIds.length || prefixo) {
    for (const idc of idsCampanha) {
      const cj = await metaTudo(`${idc}/adsets`, { fields: 'id,name,status,campaign_id' }, env, 5);
      conjuntos = conjuntos.concat(cj);
      const ad = await metaTudo(`${idc}/ads`,
        { fields: 'id,name,status,adset_id,creative{id,thumbnail_url,title,body}' }, env, 5);
      anuncios = anuncios.concat(ad);
    }
  } else {
    conjuntos = (await metaTudo(`${conta}/adsets`, { fields: 'id,name,status,campaign_id' }, env))
      .filter((a: any) => idsCampanha.includes(a.campaign_id));
    const idsConj = conjuntos.map((a: any) => a.id);
    anuncios = (await metaTudo(`${conta}/ads`,
      { fields: 'id,name,status,adset_id,creative{id,thumbnail_url,title,body}' }, env))
      .filter((a: any) => idsConj.includes(a.adset_id));
  }

  const entidades = [
    ...campanhas.map((c: any) => ({
      id: c.id, nivel: 'campaign', nome: c.name, parent_id: null,
      conta_id: conta, status: c.status, objetivo: c.objective, criativo: {},
    })),
    ...conjuntos.map((a: any) => ({
      id: a.id, nivel: 'adset', nome: a.name, parent_id: a.campaign_id,
      conta_id: conta, status: a.status, criativo: {},
    })),
    ...anuncios.map((a: any) => ({
      id: a.id, nivel: 'ad', nome: a.name, parent_id: a.adset_id,
      conta_id: conta, status: a.status,
      criativo: a.creative ? {
        id: a.creative.id, thumb: a.creative.thumbnail_url,
        titulo: a.creative.title, corpo: a.creative.body,
      } : {},
    })),
  ];

  await db.rpc('ingest_ads_entidades', { p: { lancamento: slug, entidades } });

  // ---- métricas diárias por anúncio
  const ate = new Date();
  const de = new Date(ate.getTime() - dias * 86400000);
  const fmt = (d: Date) => d.toISOString().slice(0, 10);

  const bruto = await metaTudo(`${conta}/insights`, {
    level: 'ad',
    time_increment: '1',
    time_range: JSON.stringify({ since: fmt(de), until: fmt(ate) }),
    fields: 'ad_id,impressions,reach,clicks,inline_link_clicks,inline_link_click_ctr,spend,ctr,cpm,cpc,actions,cost_per_action_type,video_play_actions',
  }, env);

  const idsAnuncio = new Set(anuncios.map((a: any) => a.id));
  const insights = bruto
    .filter((i: any) => idsAnuncio.has(i.ad_id))   // ignora anúncio fora do filtro do lançamento
    .map((i: any) => {
      // "lead" do Meta é referência; o número que vale é o do nosso banco
      const acoes = Array.isArray(i.actions) ? i.actions : [];
      const valorDe = (tipo: string) => {
        const a = acoes.find((x: any) => x.action_type === tipo);
        return a ? Number(a.value || 0) : 0;
      };

      const lead = valorDe('lead') || valorDe('offsite_conversion.fb_pixel_lead');
      const visitas = valorDe('landing_page_view');

      // "Resultado" no Gerenciador depende do objetivo da campanha.
      // Ordem de preferência: conversão de lead > visita na página > clique no link.
      let resultados = 0;
      let resultadoTipo = 'clique no link';
      if (lead > 0) { resultados = lead; resultadoTipo = 'lead'; }
      else if (visitas > 0) { resultados = visitas; resultadoTipo = 'visita na pagina'; }
      else { resultados = Number(i.inline_link_clicks || 0); }

      const video = Array.isArray(i.video_play_actions) ? i.video_play_actions[0] : null;
      return {
        visitas_pagina: visitas,
        resultados,
        resultado_tipo: resultadoTipo,
        ctr_link: i.inline_link_click_ctr ? Number(i.inline_link_click_ctr) : null,
        data_ref: i.date_start,
        ad_id: i.ad_id,
        impressoes: Number(i.impressions || 0),
        alcance: Number(i.reach || 0),
        cliques: Number(i.clicks || 0),
        cliques_link: Number(i.inline_link_clicks || 0),
        gasto: Number(i.spend || 0),
        ctr: i.ctr ? Number(i.ctr) : null,
        cpm: i.cpm ? Number(i.cpm) : null,
        cpc: i.cpc ? Number(i.cpc) : null,
        leads_meta: lead,
        video_3s: video ? Number(video.value || 0) : 0,
        raw: {},
      };
    });

  await db.rpc('ingest_ads_insights', { p: { lancamento: slug, insights } });

  return {
    conta,
    campanhas: campanhas.length,
    conjuntos: conjuntos.length,
    anuncios: anuncios.length,
    dias_metricas: insights.length,
    filtro: filtroIds.length ? 'lista de campanhas'
          : prefixo ? `campanhas que comecam com "${prefixo}"`
          : 'NENHUM — a conta inteira entrou, o investido nao representa so o lancamento',
    truncado: (anuncios as any).truncado || (campanhas as any).truncado || undefined,
  };
}

/**
 * Sincroniza todas as contas do lançamento.
 * config aceita uma conta ou várias:
 *   {"meta_account_id": "act_1"}
 *   {"meta_contas": ["act_1", "act_2"]}
 * Se uma conta falhar, as outras seguem — o erro dela volta na resposta.
 */
async function sincronizarMeta(slug: string, dias: number, db: Supabase, env: Env): Promise<any> {
  if (!env.META_TOKEN) return { ok: false, erro: 'META_TOKEN nao configurado' };

  const lanc = await db.select('lancamentos',
    { select: 'slug,codigo,config', slug: `eq.${slug}`, limit: '1' });
  if (!lanc[0]) return { ok: false, erro: `lancamento ${slug} nao encontrado` };

  const cfg = lanc[0].config || {};
  const codigo: string = lanc[0].codigo || '';
  const contas: string[] = Array.isArray(cfg.meta_contas) && cfg.meta_contas.length
    ? cfg.meta_contas
    : (cfg.meta_account_id ? [cfg.meta_account_id] : []);

  if (!contas.length) {
    return { ok: false, erro: 'nenhuma conta de anuncios no config do lancamento (meta_contas ou meta_account_id)' };
  }

  const resultados: any[] = [];
  const erros: any[] = [];

  for (const conta of contas) {
    try {
      resultados.push(await sincronizarConta(conta, slug, cfg, codigo, dias, db, env));
    } catch (e: any) {
      erros.push({ conta, erro: String(e?.message || e).slice(0, 300) });
    }
  }

  // remove o que não descende de campanha com o código do lançamento.
  // Sem isso, dado de sincronização antiga (ou campanha renomeada para
  // fora do lançamento) fica no banco e infla o investido para sempre.
  let purga: any = null;
  if (codigo) {
    purga = await db.rpc('purgar_ads', { p: { lancamento: slug } }).catch(() => null);
  }

  const total = await db.rpc('ingest_ads_insights', { p: { lancamento: slug, insights: [] } });

  return {
    ok: erros.length < contas.length,   // falha só se TODAS as contas falharem
    codigo: codigo || '(sem codigo — rode o 08_codigo_lancamento.sql)',
    limpeza: purga ? {
      entidades_removidas: purga.entidades_removidas,
      insights_removidos: purga.insights_removidos,
    } : undefined,
    contas: resultados,
    erros: erros.length ? erros : undefined,
    gasto_total: total?.gasto_total ?? 0,
  };
}

// =====================================================================
// AUTENTICAÇÃO — valida o token no próprio Supabase
// =====================================================================
const cacheToken = new Map<string, { ate: number; email: string }>();

async function usuarioDoToken(token: string | null, env: Env): Promise<string | null> {
  if (!token) return null;

  const agora = Date.now();
  const guardado = cacheToken.get(token);
  if (guardado && guardado.ate > agora) return guardado.email;

  const r = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) return null;

  const u: any = await r.json().catch(() => null);
  if (!u?.id) return null;

  // 5 minutos de cache evitam uma chamada extra a cada clique na dash
  cacheToken.set(token, { ate: agora + 5 * 60 * 1000, email: u.email || u.id });
  if (cacheToken.size > 500) cacheToken.clear();
  return u.email || u.id;
}

/** Traduz o filtro da tela em um intervalo de datas. */
function intervalo(periodo: string, de?: string | null, ate?: string | null) {
  const agora = new Date();
  const hoje = new Date(Date.UTC(agora.getUTCFullYear(), agora.getUTCMonth(), agora.getUTCDate()));
  const dia = 86400000;
  let inicio: Date;
  let fim: Date = new Date(hoje.getTime() + dia);

  switch (periodo) {
    case 'hoje':
      inicio = hoje; break;
    case 'semana': {
      const diaSemana = (hoje.getUTCDay() + 6) % 7;   // segunda = 0
      inicio = new Date(hoje.getTime() - diaSemana * dia); break;
    }
    case 'mes_passado': {
      inicio = new Date(Date.UTC(hoje.getUTCFullYear(), hoje.getUTCMonth() - 1, 1));
      fim = new Date(Date.UTC(hoje.getUTCFullYear(), hoje.getUTCMonth(), 1)); break;
    }
    case 'ano':
      inicio = new Date(Date.UTC(hoje.getUTCFullYear(), 0, 1)); break;
    case 'personalizado':
      inicio = de ? new Date(de) : new Date(Date.UTC(hoje.getUTCFullYear(), hoje.getUTCMonth(), 1));
      if (ate) fim = new Date(new Date(ate).getTime() + dia);
      break;
    case 'mes':
    default:
      inicio = new Date(Date.UTC(hoje.getUTCFullYear(), hoje.getUTCMonth(), 1));
  }
  return { inicio: inicio.toISOString(), fim: fim.toISOString() };
}

// =====================================================================
// ROTEADOR
// =====================================================================
export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const partes = url.pathname.split('/').filter(Boolean);
    const db = new Supabase(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
    const origem = req.headers.get('origin');
    const ch = corsHeaders(origem);

    try {
      if (req.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: ch });
      }

      if (partes[0] === 'health') {
        return jsonResponse({
          ok: true,
          ts: new Date().toISOString(),
          config: {
            supabase_url: !!env.SUPABASE_URL,
            supabase_key: !!env.SUPABASE_SERVICE_KEY,
            anon_key: !!env.SUPABASE_ANON_KEY,
            versao: 'v11-anuncios',
            webhook_secret: env.WEBHOOK_SECRET ? `${env.WEBHOOK_SECRET.length} chars` : false,
            debug_token: !!env.DEBUG_TOKEN,
            lancamento_padrao: env.LANCAMENTO_PADRAO || false,
            sellflux_endpoint: env.SELLFLUX_ENDPOINT ? 'configurado' : 'nao configurado',
          },
        });
      }

      // ---------------- CAPTURA (formulário próprio)
      if (partes[0] === 'captura' && req.method === 'POST') {
        const body = await safeJson(req);

        // honeypot: campo invisível preenchido = bot. Responde ok e descarta.
        if (s(body?.empresa) || s(body?.website)) {
          return jsonResponse({ ok: true, recebido: true }, 200, ch);
        }

        // preenchimento humano leva mais de 2 segundos
        const decorrido = Number(body?.tempo_ms || 0);
        if (decorrido > 0 && decorrido < 2000) {
          return jsonResponse({ ok: true, recebido: true }, 200, ch);
        }

        const email = s(achar(body, EMAIL_KEYS));
        const telefone = s(achar(body, FONE_KEYS));
        if (!email && !telefone) {
          return jsonResponse({ ok: false, erro: 'informe e-mail ou telefone' }, 400, ch);
        }

        const { utm, meta, fbclid, landing_url } = extrairUtm(body);
        const dados = {
          lancamento: s(body?.lancamento) || env.LANCAMENTO_PADRAO,
          email, telefone,
          nome: s(achar(body, NOME_KEYS)),
          origem: 'form_proprio',
          utm, meta, fbclid, landing_url,
          extras: {
            user_agent: req.headers.get('user-agent') || '',
            pais: (req as any).cf?.country || '',
          },
          payload: { formulario: s(body?.formulario) || 'captura' },
        };

        // 1) banco primeiro — é a fonte da verdade
        const r = await db.rpc('ingest_lead', { p: dados });
        if (r?.ok === false) {
          return jsonResponse({ ok: false, erro: r.erro }, 400, ch);
        }

        // 2) SellFlux depois, sem segurar a resposta ao lead
        ctx.waitUntil(repassarSellflux(dados, env, db, r?.pessoa_id));

        return jsonResponse({
          ok: true, inscricao_id: r?.inscricao_id, novo: r?.novo,
        }, 200, ch);
      }

      // ---------------- WEBHOOK de ferramenta
      if (partes[0] === 'w' && req.method === 'POST') {
        const fonte = (partes[1] || '').toLowerCase();
        const secret = partes[2] || url.searchParams.get('k') || '';
        if (secret !== env.WEBHOOK_SECRET) return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
        if (!FONTES_VALIDAS.includes(fonte)) return jsonResponse({ ok: false, erro: 'fonte desconhecida' }, 400, ch);

        const body = await safeJson(req);
        const headers: Record<string, string> = {};
        req.headers.forEach((v, k) => { headers[k] = v; });

        const raw = await db.insert('webhooks_raw', { fonte, headers, body, processado: false }, 'dash');
        const rawId = raw?.[0]?.id ?? null;

        ctx.waitUntil(processar(fonte, body, rawId, db, env));
        return jsonResponse({ ok: true, recebido: true, raw_id: rawId }, 200, ch);
      }

      // ---------------- REDIRECT PRO GRUPO
      if (partes[0] === 'r' && partes[1] === 'grupo') {
        if ((partes[2] || '') !== env.WEBHOOK_SECRET) {
          return new Response('Link inválido.', { status: 403 });
        }
        const inscricaoId = url.searchParams.get('i');
        const slug = url.searchParams.get('l') || env.LANCAMENTO_PADRAO;

        const lanc = await db.select('lancamentos',
          { select: 'id,slug,config', slug: `eq.${slug}`, limit: '1' }, 'dash');
        const destino = lanc?.[0]?.config?.grupo_url;
        if (!destino) return new Response('Grupo indisponível no momento.', { status: 404 });

        if (inscricaoId) {
          ctx.waitUntil(db.rpc('ingest_evento', {
            p: {
              inscricao_id: inscricaoId, tipo: 'grupo_click', fonte: 'interno',
              lancamento: lanc[0].slug,
              payload: { ua: req.headers.get('user-agent') || '' },
            },
          }).catch(() => {}));
        }
        return Response.redirect(destino, 302);
      }

      // ---------------- DEBUG
      if (partes[0] === 'debug' && partes[1] === 'ultimos') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
        }
        const filtros: Record<string, string> = {
          select: 'id,fonte,recebido_em,processado,erro,body',
          order: 'recebido_em.desc',
          limit: url.searchParams.get('n') || '5',
        };
        const fonte = url.searchParams.get('fonte');
        if (fonte) filtros.fonte = `eq.${fonte}`;
        const dados = await db.select('webhooks_raw', filtros, 'dash');
        return jsonResponse({ ok: true, total: dados.length, dados });
      }

      if (partes[0] === 'debug' && partes[1] === 'reprocessar' && req.method === 'POST') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
        }
        const pendentes = await db.select('webhooks_raw',
          { select: 'id,fonte,body', processado: 'eq.false', order: 'recebido_em.asc', limit: '100' }, 'dash');
        let ok = 0, falhou = 0;
        for (const p of pendentes) {
          try { await processar(p.fonte, p.body, p.id, db, env); ok++; } catch { falhou++; }
        }
        return jsonResponse({ ok: true, reprocessados: ok, falharam: falhou }, 200, ch);
      }

      // ============ SINCRONIZAÇÃO MANUAL DO META ============
      if (partes[0] === 'sync' && partes[1] === 'meta') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
        }
        const slug = url.searchParams.get('lancamento') || env.LANCAMENTO_PADRAO || '';
        const dias = Math.min(90, Number(url.searchParams.get('dias') || 30));
        const r = await sincronizarMeta(slug, dias, db, env);
        return jsonResponse(r, r.ok ? 200 : 400, ch);
      }

      // ============ API DA DASH ============
      if (partes[0] === 'api') {
        // -------- login: o front nunca fala direto com o Supabase
        if (partes[1] === 'login' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await fetch(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY },
            body: JSON.stringify({ email: corpo.email || '', password: corpo.senha || '' }),
          });
          const d: any = await r.json().catch(() => ({}));

          if (!r.ok || !d.access_token) {
            await new Promise((res) => setTimeout(res, 500));
            return jsonResponse({ ok: false, erro: 'e-mail ou senha incorretos' }, 401, ch);
          }
          return jsonResponse({
            ok: true,
            token: d.access_token,
            refresh: d.refresh_token,
            expira_em: d.expires_in || 3600,
            email: d.user?.email || corpo.email,
          }, 200, ch);
        }

        // -------- renovação do token
        if (partes[1] === 'refresh' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await fetch(`${env.SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY },
            body: JSON.stringify({ refresh_token: corpo.refresh || '' }),
          });
          const d: any = await r.json().catch(() => ({}));
          if (!r.ok || !d.access_token) {
            return jsonResponse({ ok: false, erro: 'sessao expirada' }, 401, ch);
          }
          return jsonResponse({
            ok: true, token: d.access_token, refresh: d.refresh_token,
            expira_em: d.expires_in || 3600,
          }, 200, ch);
        }

        const auth = req.headers.get('authorization') || '';
        const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
        const usuario = await usuarioDoToken(token, env);
        if (!usuario) return jsonResponse({ ok: false, erro: 'nao autenticado' }, 401, ch);

        const slug = url.searchParams.get('lancamento') || '';

        // -------- lançamentos
        if (partes[1] === 'sugerir-codigo') {
          const r = await db.rpc('sugerir_codigo', {
            p: { captacao_inicio: url.searchParams.get('inicio') || null },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'alterar-codigo' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('alterar_codigo', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'lancamentos' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('criar_lancamento', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'lancamentos') {
          const dados = await db.select('lancamentos', {
            select: 'id,slug,codigo,nome,status,captacao_inicio,carrinho_abre,carrinho_fecha,meta_leads,investimento_planejado',
            order: 'criado_em.desc',
          });
          return jsonResponse({ ok: true, dados }, 200, ch);
        }

        // -------- home: os 3 cards em uma chamada só
        if (partes[1] === 'home') {
          const periodo = url.searchParams.get('periodo') || 'mes';
          const { inicio, fim } = intervalo(
            periodo, url.searchParams.get('de'), url.searchParams.get('ate')
          );
          const dias = Number(url.searchParams.get('dias') || 30);

          const [receita, captura, serie] = await Promise.all([
            db.rpc('dash_receita', { p: { inicio, fim } }),
            db.rpc('dash_captura', { p: { lancamento: slug } }),
            db.rpc('dash_serie_diaria', { p: { lancamento: slug, dias } }),
          ]);

          return jsonResponse({ ok: true, usuario, receita, captura, serie }, 200, ch);
        }

        // -------- lista de leads
        if (partes[1] === 'anuncios') {
          const r = await db.rpc('dash_anuncios', { p: { lancamento: slug } });
          return jsonResponse({ ok: true, ...r }, 200, ch);
        }

        if (partes[1] === 'leads') {
          const pagina = Math.max(0, Number(url.searchParams.get('pagina') || 0));
          const porPagina = Math.min(100, Number(url.searchParams.get('limite') || 50));
          const etapa = url.searchParams.get('etapa') || '';
          const busca = url.searchParams.get('busca') || '';

          const filtros: Record<string, string> = {
            select: 'id,capturado_em,etapa,lead_score,lead_tier,engenheiro,fez_quiz,entrou_grupo,'
                  + 'comprou,utm_campaign,utm_content,meta_ad_id,origem_sistema,'
                  + 'pessoas(nome,email,telefone)',
            order: 'capturado_em.desc',
            limit: String(porPagina),
            offset: String(pagina * porPagina),
          };

          if (slug) {
            const lanc = await db.select('lancamentos', { select: 'id', slug: `eq.${slug}`, limit: '1' });
            if (lanc[0]) filtros.lancamento_id = `eq.${lanc[0].id}`;
          }
          if (etapa) filtros.etapa = `eq.${etapa}`;
          if (busca) filtros['pessoas.email'] = `ilike.*${busca}*`;

          const dados = await db.select('inscricoes', filtros);
          return jsonResponse({ ok: true, dados, pagina }, 200, ch);
        }

        // -------- ficha do lead
        if (partes[1] === 'lead' && partes[2]) {
          const id = partes[2];
          const ficha = await db.select('inscricoes', {
            select: '*,pessoas(nome,email,telefone,primeiro_contato)',
            id: `eq.${id}`, limit: '1',
          });
          if (!ficha[0]) return jsonResponse({ ok: false, erro: 'lead nao encontrado' }, 404, ch);

          const [eventos, quiz] = await Promise.all([
            db.select('eventos', {
              select: 'tipo,ocorreu_em,fonte,payload',
              inscricao_id: `eq.${id}`, order: 'ocorreu_em.asc', limit: '200',
            }),
            db.select('quiz_respostas', {
              select: 'pergunta_chave,resposta_label,resposta_valor,pontos',
              inscricao_id: `eq.${id}`, order: 'respondido_em.asc',
            }),
          ]);

          return jsonResponse({ ok: true, lead: ficha[0], eventos, quiz }, 200, ch);
        }


        return jsonResponse({ ok: false, erro: 'rota nao encontrada' }, 404, ch);
      }

      return jsonResponse({ ok: false, erro: 'rota nao encontrada', caminho: url.pathname }, 404, ch);
    } catch (e: any) {
      return jsonResponse({ ok: false, erro: String(e?.message || e) }, 500, ch);
    }
  },

  // Cron: sincroniza o Meta de hora em hora, para todo lançamento em andamento.
  async scheduled(_evento: ScheduledController, env: Env, ctx: ExecutionContext) {
    const db = new Supabase(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
    ctx.waitUntil((async () => {
      try {
        const ativos = await db.select('lancamentos', {
          select: 'slug',
          status: 'in.(captacao,aquecimento,evento,carrinho)',
        });
        for (const l of ativos) {
          try {
            const r = await sincronizarMeta(l.slug, 7, db, env);
            if (!r.ok) {
              await db.insert('webhooks_raw', {
                fonte: 'sync_meta_falhou', body: { lancamento: l.slug },
                processado: false, erro: String(r.erro).slice(0, 400),
              }).catch(() => {});
            }
          } catch (e: any) {
            await db.insert('webhooks_raw', {
              fonte: 'sync_meta_falhou', body: { lancamento: l.slug },
              processado: false, erro: String(e?.message || e).slice(0, 400),
            }).catch(() => {});
          }
        }
      } catch {}
    })());
  },
};
