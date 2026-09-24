/**
 * DASH DE LANÇAMENTO — WORKER ÚNICO
 * Arquivo único na raiz do repositório. Faz a ingestão E serve a dash.
 *
 * ---- ENTRADA DE DADOS ----
 *   POST /captura              formulário próprio -> banco -> SellFlux + ManyChat
 *   POST /w/:fonte/:secret     webhook (hotmart, sellflux, manychat, sendflow, quiz)
 *   GET  /r/grupo/:secret      redirect rastreado para o grupo de WhatsApp
 *   GET  /r/tmb/:inscricao     redirect rastreado para o financiamento TMB
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
  // O segredo da URL do conector MCP. Sem ele configurado a rota não
  // existe — nada fica exposto por acidente.
  MCP_SEGREDO?: string;
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
  HOTMART_HOTTOK?: string;       // valida que o webhook veio mesmo da Hotmart
  TMB_TOKEN?: string;            // reserva; o normal é configurar pela tela
  MANYCHAT_TOKEN?: string;
  MANYCHAT_TAG?: string;
  MANYCHAT_FLOW?: string;
  MANYCHAT_CAMPO?: string;
  MANYCHAT_FIELD_ID?: string;
  MANYCHAT_CAMPO_FONE?: string;
  META_CONTAS?: string;
  MANYCHAT_TAG_RECUPERACAO?: string;
  PAGINA_QUIZ?: string;
  R2_PUBLICO?: string;
  R2_ACCOUNT_ID?: string;
  R2_BUCKET?: string;
  R2_ACCESS_KEY_ID?: string;
  R2_SECRET_ACCESS_KEY?: string;
  SELLFLUX_REATIVACAO?: string;
  META_PIXEL_ID?: string;
  META_CAPI_TOKEN?: string;
  META_TEST_EVENT?: string;
  VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_KEY?: string;
  VAPID_CONTATO?: string;
}

const FONTES_VALIDAS = ['sellflux', 'quiz', 'sendflow', 'manychat',
                        'hotmart', 'kiwify', 'herospark', 'guru', 'tmb',
                        'tmb-financeiro', 'teste'];

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
                   'mobile', 'lead_phone', 'buyer_phone', 'wa_id', 'numero',
                   // o SendFlow chama de "number" no evento de entrada no grupo
                   'number'];
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

/**
 * O SendFlow manda vários tipos de aviso no mesmo webhook, e só um
 * deles diz que alguém entrou no grupo:
 *
 *   group.updated.members.added     entrou      → interessa
 *   group.updated.members.removed   saiu        → interessa
 *   campaign.message.metrics        estatística → não é pessoa
 *   campaign.metrics                estatística → não é pessoa
 *
 * Os de estatística não têm telefone, e tentar processá-los gerava
 * "sem identificador" no log — erro que escondia problema de verdade.
 */
function eventoDeGrupo(body: any): boolean {
  const evento = String(body?.event || body?.evento || '').toLowerCase();
  if (!evento) return true;                 // formato antigo, sem tipo
  if (evento.includes('metric')) return false;
  return /member|group|participant/.test(evento);
}

function parseSendflow(body: any, lp?: string, rawId?: number | null) {
  const evento = (s(achar(body, ['event', 'evento', 'tipo', 'action', 'status'])) || '')
    .toLowerCase();

  // "removed" e "left" indicam saída; o resto é entrada
  let tipo = 'grupo_entrou';
  if (/(removed|left|sai|remov|exit)/.test(evento)) tipo = 'grupo_saiu';

  const d = body?.data || body;

  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lp,
    email: s(achar(body, EMAIL_KEYS)),
    // number é o campo do SendFlow; os outros ficam de reserva
    telefone: s(d?.number) || s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    tipo, fonte: 'sendflow',
    // createdAt vem em camelCase, que a busca por chave normalizada pega
    ocorreu_em: s(d?.createdAt) || s(achar(body, ['created_at', 'timestamp', 'date'])),
    payload: {
      grupo: s(d?.groupName) || s(achar(body, ['grupo', 'group', 'group_name'])),
      grupo_id: s(d?.groupId),
      campanha: s(d?.campaignName),
      evento_original: evento,
      raw: body,
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

// O status pode chegar de dois jeitos: purchase.status na v2 ("APPROVED")
// ou o nome do evento na v1 ("PURCHASE_APPROVED"). Os dois estão aqui.
const STATUS_HOTMART: Record<string, string> = {
  approved: 'aprovada',
  complete: 'aprovada',
  completed: 'aprovada',
  paid: 'aprovada',
  purchase_approved: 'aprovada',
  purchase_complete: 'aprovada',

  waiting_payment: 'pendente',
  started: 'pendente',
  under_analisys: 'pendente',
  under_analysis: 'pendente',
  overdue: 'pendente',
  printed_billet: 'pendente',
  billet_printed: 'pendente',
  purchase_billet_printed: 'pendente',
  purchase_delayed: 'pendente',

  canceled: 'cancelada',
  cancelled: 'cancelada',
  expired: 'cancelada',
  blocked: 'cancelada',
  purchase_canceled: 'cancelada',
  purchase_expired: 'cancelada',
  purchase_out_of_shopping_cart: 'cancelada',

  refunded: 'reembolsada',
  purchase_refunded: 'reembolsada',

  chargeback: 'chargeback',
  protested: 'chargeback',
  purchase_protest: 'chargeback',
  purchase_chargeback: 'chargeback',
};

/**
 * A Hotmart v2 aninha tudo em objetos, e a busca genérica por nome de
 * chave encontra a coisa errada:
 *
 *   price      é { value, currency_value } — a busca ignora objeto e
 *              devolve undefined, então o valor virava zero
 *   name       existe em buyer E em product — a busca achava o do
 *              comprador primeiro e gravava como nome do produto
 *   event      "PURCHASE_APPROVED" era lido como status, que não bate
 *              com nenhuma chave conhecida, e tudo virava "pendente"
 *
 * Por isso este parser lê caminhos explícitos. A busca genérica fica de
 * reserva, para o formato antigo (v1) que ainda pode chegar.
 */
function parseHotmart(body: any, lp?: string, rawId?: number | null) {
  const d = body?.data || {};
  const compra = d.purchase || {};
  const comprador = d.buyer || d.user || {};
  const produto = d.product || {};

  // o status da compra, não o nome do evento
  // purchase.status na v2, status solto na v1, nome do evento por último
  const bruto = String(
    compra.status
    || d.status
    || body?.status
    || s(achar(body, ['transaction_status']))
    || body?.event
    || '',
  ).toLowerCase();

  // o valor vive em price.value; full_price é o preço cheio antes de
  // desconto, e serve de reserva
  // na v2 o preço é objeto; na v1 é número solto
  const valor =
    Number(compra.price?.value)
    || Number(compra.full_price?.value)
    || Number(compra.original_offer_price?.value)
    || Number(typeof body?.price === 'number' ? body.price : NaN)
    || Number(typeof body?.full_price === 'number' ? body.full_price : NaN)
    || Number(achar(body, ['valor', 'total', 'amount']) ?? 0)
    || 0;

  // o que sobra para o produtor depois das comissões
  const comissoes = Array.isArray(d.commissions) ? d.commissions : [];
  const doProdutor = comissoes.find((c: any) =>
    String(c?.source || '').toUpperCase() === 'PRODUCER');
  const liquido =
    Number(doProdutor?.value)
    || Number(comissoes[0]?.value)
    || Number(achar(body, ['producer_value']) ?? 0)
    || 0;

  const metodoBruto = String(
    compra.payment?.type || compra.payment_type
    || s(achar(body, ['payment_method', 'metodo'])) || '',
  ).toLowerCase();

  const metodo = /pix/.test(metodoBruto) ? 'pix'
               : /(billet|boleto|bank_slip)/.test(metodoBruto) ? 'boleto'
               : /(credit|card|cartao)/.test(metodoBruto) ? 'cartao'
               : metodoBruto || undefined;

  const fone = comprador.checkout_phone?.number
            || comprador.phone
            || s(achar(comprador, FONE_KEYS));

  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lp,
    plataforma: 'hotmart',

    transacao_id: s(compra.transaction || d.transaction
                    || achar(body, ['transaction_id', 'order_id']))
                  || (rawId ? `raw-${rawId}` : `sem-id-${Date.now()}`),

    // do objeto product, nunca do buyer
    produto: s(produto.name || produto.product_name
               || achar(body, ['prod_name', 'produto'])),
    produto_id: s(produto.id || produto.ucode),

    oferta: s(compra.offer?.code || compra.offer?.key
              || achar(body, ['offer_code', 'oferta'])),

    status: STATUS_HOTMART[bruto] || (/(approv|complet|paid)/.test(bruto)
      ? 'aprovada' : 'pendente'),

    metodo,
    parcelas: s(compra.payment?.installments_number
                || achar(body, ['installments_number', 'parcelas'])),

    valor_bruto: valor,
    valor_liquido: liquido,
    moeda: s(compra.price?.currency_value || compra.full_price?.currency_value
             || achar(body, ['currency', 'currency_code'])) || 'BRL',

    nome: s(comprador.name || achar(comprador, NOME_KEYS)),
    email: s(comprador.email || achar(comprador, EMAIL_KEYS)),
    telefone: s(fone),

    src: s(compra.sckPaymentLink || compra.sck
           || achar(body, ['src', 'source'])),

    // approved_date é quando o dinheiro entrou; order_date é quando o
    // pedido foi feito. Para faturamento vale o primeiro.
    ocorreu_em: s(compra.approved_date || compra.order_date
                  || body?.creation_date
                  || achar(body, ['purchase_date', 'timestamp'])),

    raw: body,
  };
}

// ---------------------------------------------------------------------
// KIWIFY — valores vêm em centavos
// ---------------------------------------------------------------------
const STATUS_KIWIFY: Record<string, string> = {
  paid: 'aprovada', approved: 'aprovada',
  waiting_payment: 'pendente', pending: 'pendente',
  refused: 'cancelada', canceled: 'cancelada',
  refunded: 'reembolsada', chargedback: 'chargeback', chargeback: 'chargeback',
};

function parseKiwify(body: any, lp?: string, rawId?: number | null) {
  const bruto = (s(achar(body, ['order_status', 'status', 'webhook_event_type'])) || '').toLowerCase();

  // centavos -> reais. O campo muda de nome conforme o evento.
  const centavos = Number(
    achar(body, ['charge_amount', 'product_base_price', 'order_amount', 'total']) ?? 0
  ) || 0;
  const comissao = Number(achar(body, ['my_commission', 'producer_commission']) ?? 0) || 0;

  const metodoBruto = (s(achar(body, ['payment_method'])) || '').toLowerCase();

  return {
    lancamento: lp,
    plataforma: 'kiwify',
    transacao_id: s(achar(body, ['order_id', 'order_ref', 'id']))
                  || (rawId ? `raw-${rawId}` : `sem-id-${Date.now()}`),
    produto: s(achar(body, ['product_name', 'produto'])),
    oferta: s(achar(body, ['offer_name', 'product_id'])),
    status: STATUS_KIWIFY[bruto] || 'pendente',
    metodo: /pix/.test(metodoBruto) ? 'pix'
          : /boleto/.test(metodoBruto) ? 'boleto'
          : /(credit|card)/.test(metodoBruto) ? 'cartao' : metodoBruto || undefined,
    parcelas: s(achar(body, ['installments'])),
    valor_bruto: centavos / 100,
    valor_liquido: comissao / 100,
    moeda: s(achar(body, ['currency'])) || 'BRL',
    email: s(achar(body, ['email', 'customer_email'])),
    telefone: s(achar(body, ['mobile', 'phone', 'customer_mobile'])),
    src: s(achar(body, ['src', 'sck', 'utm_source'])),
    ocorreu_em: s(achar(body, ['created_at', 'approved_date', 'updated_at'])),
    raw: body,
  };
}

// ---------------------------------------------------------------------
// HERO SPARK — o corpo é montado por nós na automação, então os nomes
// já chegam prontos. Ainda assim o parser aceita variações.
// ---------------------------------------------------------------------
function parseHerospark(body: any, lp?: string, rawId?: number | null) {
  const evento = (s(achar(body, ['evento', 'event', 'status'])) || '').toLowerCase();
  const valor = Number(
    String(achar(body, ['valor', 'payment_total', 'total', 'amount']) ?? '0')
      .replace(/[^0-9,.-]/g, '').replace(',', '.')
  ) || 0;

  const metodoBruto = (s(achar(body, ['metodo', 'payment_method'])) || '').toLowerCase();

  return {
    lancamento: lp,
    plataforma: 'herospark',
    transacao_id: s(achar(body, ['transacao', 'payment_id', 'id']))
                  || (rawId ? `raw-${rawId}` : `sem-id-${Date.now()}`),
    produto: s(achar(body, ['produto', 'product_name'])),
    oferta: s(achar(body, ['produto_id', 'product_id'])),
    status: STATUS_HOTMART[evento] || (evento.includes('approved') ? 'aprovada' : 'pendente'),
    metodo: /pix/.test(metodoBruto) ? 'pix'
          : /(billet|boleto)/.test(metodoBruto) ? 'boleto'
          : /(credit|card|cartao)/.test(metodoBruto) ? 'cartao' : metodoBruto || undefined,
    valor_bruto: valor,
    valor_liquido: 0,
    moeda: 'BRL',
    email: s(achar(body, ['email', 'buyer_email'])),
    telefone: s(achar(body, ['telefone', 'buyer_phone'])),
    ocorreu_em: s(achar(body, ['data', 'created_at'])),
    raw: body,
  };
}

// ---------------------------------------------------------------------
// TMB EDUCAÇÃO — parcelamento no boleto
//
// Dois valores importam e são diferentes: valor_principal é o ticket do
// produto; valor_total é o que o aluno paga com juros do financiamento.
// Quem fatura o produtor é o principal, então é ele que vai para a
// receita — usar o total inflaria o faturamento em até 5x.
//
// A TMB também manda UTM de primeiro e último toque. Guardamos as duas.
// ---------------------------------------------------------------------
function parseTMB(body: any, lp?: string, rawId?: number | null) {
  const situacao = (s(achar(body, ['status_pedido'])) || '').toLowerCase();

  const status = situacao.includes('efetiv') ? 'aprovada'
               : situacao.includes('cancel') ? 'cancelada'
               : situacao.includes('reembols') || situacao.includes('estorn') ? 'reembolsada'
               : 'pendente';

  const principal = Number(achar(body, ['valor_principal']) ?? 0) || 0;
  const total = Number(achar(body, ['valor_total']) ?? 0) || 0;
  const taxa = Number(achar(body, ['taxa_administracao']) ?? 0) || 0;
  const parcelas = Number(achar(body, ['parcelas']) ?? 0) || 0;

  // Boleto parcelado: o faturamento é o valor total do contrato, e ele
  // entra no caixa parcela a parcela. O webhook financeiro diz quanto
  // já pingou; aqui fica o contratado.
  const bruto = total > 0 ? total : principal;

  return {
    lancamento: lp,
    plataforma: 'tmb',
    transacao_id: s(achar(body, ['pedido', 'pedido_id', 'id']))
                  || (rawId ? `raw-${rawId}` : `sem-id-${Date.now()}`),
    produto: s(achar(body, ['lancamento_nome', 'titulo'])) || s(body?.lancamento),
    oferta: s(achar(body, ['code', 'lancamento_id'])),
    status,
    metodo: 'boleto',
    parcelas: s(achar(body, ['parcelas'])),
    valor_bruto: bruto,
    valor_liquido: taxa > 0 ? Number((bruto * (1 - taxa / 100)).toFixed(2)) : 0,
    moeda: 'BRL',
    email: s(achar(body, ['email'])),
    telefone: s(achar(body, ['telefone_ativo', 'telefones'])),
    src: s(achar(body, ['utm_source'])),
    ocorreu_em: s(achar(body, ['data_efetivado', 'criado_em'])),
    raw: {
      ...body,
      _ticket_produto: principal,
      _parcelas: parcelas,
    },
  };
}

// =====================================================================
// REPASSES (rodam depois de gravar; nunca seguram a resposta ao lead)
// Os endereços configurados na tela de Integrações vencem os secrets do
// Worker — assim o cliente muda sem precisar de deploy.
// =====================================================================
async function repassar(dados: any, env: Env, db: Supabase, pessoaId?: string) {
  const cfgSellflux = await segredoIntegracao('sellflux', 'endpoint', db);
  const cfgManychat = await segredoIntegracao('manychat', 'webhook', db);

  const urlSellflux = (cfgSellflux?.ativa && cfgSellflux?.valor) || env.SELLFLUX_ENDPOINT;
  const urlManychat = (cfgManychat?.ativa && cfgManychat?.valor) || env.MANYCHAT_WEBHOOK;

  const corpo = new URLSearchParams();
  corpo.set('name', dados.nome || '');
  corpo.set('email', dados.email || '');

  // O formulário do SellFlux manda DDI e telefone em campos separados.
  // Mandar +5553999887766 num campo só costuma virar telefone inválido
  // do lado dele, e aí a automação de WhatsApp não encontra o contato.
  const fone = String(dados.telefone || '');
  if (fone.startsWith('+55')) {
    corpo.set('ddi', '55');
    corpo.set('phone', fone.slice(3));
  } else if (fone.startsWith('+')) {
    // DDI tem 1 a 3 dígitos; sem uma lista, +1 vira "12" e o número quebra
    const so = fone.slice(1);
    const DDIS = ['1', '351', '34', '39', '44', '49', '54', '56', '57', '58',
                  '595', '598', '244', '258', '61', '81'];
    const achado = DDIS.sort((a, b) => b.length - a.length)
                       .find((d) => so.startsWith(d));
    corpo.set('ddi', achado || so.slice(0, 2));
    corpo.set('phone', achado ? so.slice(achado.length) : so.slice(2));
  } else {
    corpo.set('ddi', '55');
    corpo.set('phone', fone.replace(/\D/g, ''));
  }
  if (dados.utm?.source)   corpo.set('utm_source', dados.utm.source);
  if (dados.utm?.medium)   corpo.set('utm_medium', dados.utm.medium);
  if (dados.utm?.campaign) corpo.set('utm_campaign', dados.utm.campaign);
  if (dados.utm?.content)  corpo.set('utm_content', dados.utm.content);
  if (dados.meta?.ad_id)   corpo.set('adid', dados.meta.ad_id);
  if (dados.landing_url)   corpo.set('url', dados.landing_url);
  if (dados.lancamento)    corpo.set('lancamento', dados.lancamento);

  // --- SellFlux (dispara a sequência de e-mail)
  if (urlSellflux) {
    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    if (env.SELLFLUX_TOKEN) headers['Authorization'] = `Bearer ${env.SELLFLUX_TOKEN}`;
    try {
      const r = await fetch(urlSellflux, { method: 'POST', headers, body: corpo });
      if (!r.ok) throw new Error(`sellflux ${r.status}`);
    } catch (e: any) {
      // o lead já está no banco; registra a falha para reenvio
      await db.insert('webhooks_raw', {
        fonte: 'saida_sellflux_falhou',
        body: { dados, pessoa_id: pessoaId },
        processado: false,
        erro: String(e?.message || e).slice(0, 400),
      }).catch(() => {});
    }
  }

  // --- ManyChat
  //
  // Dois caminhos, escolhidos na tela de Integrações:
  //
  //   DIRETO   a dash fala com a API do ManyChat. Cria o contato ou, se
  //            já existir, encontra pelo telefone. Menos uma peça no
  //            meio e a falha aparece na hora.
  //
  //   VIA n8n  mantém o webhook intermediário, para quem já tem o
  //            workflow montado e não quer mexer.
  const cfgDireto = await segredoIntegracao('manychat_api', 'token', db);

  // Token e fluxo vivem nas variáveis do Worker. A tela só liga e
  // desliga — sem campos para preencher, não há como salvar um valor
  // errado que passe a valer sobre a variável.
  const tokenManychat = env.MANYCHAT_TOKEN || '';
  const usarDireto = !!(cfgDireto?.ativa && tokenManychat);

  if (cfgDireto?.ativa && !tokenManychat) {
    // ativa na tela mas sem o secret: o lead sumiria sem explicação
    await db.insert('webhooks_raw', {
      fonte: 'manychat_sem_token',
      body: { pessoa_id: pessoaId },
      processado: false,
      erro: 'ManyChat esta ativo mas MANYCHAT_TOKEN nao esta configurado no Worker',
    }).catch(() => {});
  }

  if (usarDireto) {
    try {
      const r: any = await enviarManychat(
        {
          nome: dados.nome,
          email: dados.email,
          telefone: dados.telefone,
          lancamento: dados.lancamento,
        },
        {
          token: tokenManychat,
          flow_ns: env.MANYCHAT_FLOW || '',
          tag: env.MANYCHAT_TAG || '',
          campo_lancamento: env.MANYCHAT_CAMPO || '',
          campo_telefone: env.MANYCHAT_CAMPO_FONE || '',
          field_id: env.MANYCHAT_FIELD_ID || '',
        },
      );
      // o registro traz o que foi enviado: sem isso, "Validation error"
      // não diz qual campo o ManyChat recusou
      if (!r.ok) {
        await db.insert('webhooks_raw', {
          fonte: 'saida_manychat_falhou',
          body: {
            enviado: r.enviado,
            resposta_manychat: r.resposta,
            passos: r.passos,
            pessoa_id: pessoaId,
            telefone: dados.telefone,
          },
          processado: false,
          erro: String(r.erro || 'falha').slice(0, 400),
        }).catch(() => {});
        // marca para o catch não registrar de novo o mesmo erro
        const jaRegistrado = new Error(r.erro || 'falha no ManyChat');
        (jaRegistrado as any).registrado = true;
        throw jaRegistrado;
      }

      // tag que não aplicou não derruba o lead, mas fica registrada:
      // sem ela o fluxo do WhatsApp pode não disparar
      // Fluxo recusado por contato inativo COM a tag aplicada não é
      // falha: é o caminho previsto funcionando. Registrar como erro
      // enche a tela de saúde e esconde problema de verdade.
      const fluxoEsperado = r.aviso_fluxo
        && /not active/i.test(r.aviso_fluxo)
        && r.tag_aplicada;

      if (r.aviso_tag || (r.aviso_fluxo && !fluxoEsperado)) {
        await db.insert('webhooks_raw', {
          fonte: 'manychat_parcial',
          body: { subscriber_id: r.subscriber_id, passos: r.passos },
          processado: false,
          erro: [r.aviso_tag && `tag: ${r.aviso_tag}`,
                 r.aviso_fluxo && `fluxo: ${r.aviso_fluxo}`]
                .filter(Boolean).join(' | ').slice(0, 400),
        }).catch(() => {});
      }
    } catch (e: any) {
      if (!e?.registrado) {
        await db.insert('webhooks_raw', {
          fonte: 'saida_manychat_falhou',
          body: { dados, pessoa_id: pessoaId },
          processado: false,
          erro: String(e?.message || e).slice(0, 400),
        }).catch(() => {});
      }
    }
  } else if (urlManychat) {
    try {
      const comoJson = (cfgManychat?.config?.formato || 'json') === 'json';

      const r = await fetch(urlManychat, comoJson
        ? {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(Object.fromEntries(corpo)),
          }
        : {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: corpo,
          });
      if (!r.ok) throw new Error(`n8n ${r.status}`);
    } catch (e: any) {
      await db.insert('webhooks_raw', {
        fonte: 'saida_manychat_falhou',
        body: { enviado: Object.fromEntries(corpo), pessoa_id: pessoaId },
        processado: false,
        erro: String(e?.message || e).slice(0, 400),
      }).catch(() => {});
    }
  }
}

// =====================================================================
// PROCESSAMENTO DE WEBHOOK DE ENTRADA
// =====================================================================
/**
 * `lancamento` vem da URL do webhook (?l=slug). Isso permite ter uma
 * conexão por lançamento na mesma plataforma — no SendFlow, por exemplo,
 * cada campanha de grupo aponta para a URL do seu lançamento. Sem isso,
 * tudo cairia no lançamento padrão do Worker.
 */
async function processar(
  fonte: string, body: any, rawId: number | null,
  db: Supabase, env: Env, lancamento?: string,
) {
  try {
    let resultado: any;
    // Webhook de lead novo: não existe inscrição ainda, então o ativo
    // é o melhor palpite disponível. Se houver dois ativos, o mais
    // recente vence — por isso encerrar o lançamento anterior importa.
    const lp = lancamento || await slugAtivo(db, env);
    switch (fonte) {
      case 'sellflux':
      case 'teste':
        resultado = await db.rpc('ingest_lead', { p: parseSellflux(body, lp, rawId) });
        // se o aviso trouxe tags ou etapa, espelha o estado do SellFlux
        if (fonte === 'sellflux' && (body?.tags || body?.stage_id)) {
          await db.rpc('ingest_sellflux_estado', {
            p: {
              lancamento: lp,
              email: s(achar(body, EMAIL_KEYS)),
              telefone: s(achar(body, FONE_KEYS)),
              tags: Array.isArray(body.tags) ? body.tags : [],
              stage_id: body.stage_id ? String(body.stage_id) : null,
            },
          }).catch(() => {});
        }
        break;
      case 'quiz':
        resultado = await db.rpc('ingest_quiz', { p: parseQuiz(body, lp, rawId) }); break;
      case 'sendflow': {
        // aviso de estatística não é pessoa entrando: marcamos como
        // processado para não virar erro na tela de saúde
        if (!eventoDeGrupo(body)) {
          if (rawId) {
            await db.update('webhooks_raw', { id: `eq.${rawId}` }, {
              processado: true,
              erro: `ignorado: ${String(body?.event || 'evento sem pessoa')}`,
            }, 'dash').catch(() => {});
          }
          return;
        }
        resultado = await db.rpc('ingest_evento', { p: parseSendflow(body, lp, rawId) });
        break;
      }
      case 'manychat':
        resultado = await db.rpc('ingest_evento', { p: parseManychat(body, lp, rawId) }); break;
      case 'hotmart':
      case 'guru': {
        // evento que não é compra sai daqui como processado, não como
        // erro: ele chegou certo, só não interessa para a dash
        if (fonte === 'hotmart' && !ehVendaHotmart(body)) {
          if (rawId) {
            await db.update('webhooks_raw', { id: `eq.${rawId}` }, {
              processado: true,
              erro: `ignorado: ${String(body?.event || 'evento sem venda')}`,
            }, 'dash').catch(() => {});
          }
          return;
        }
        resultado = await db.rpc('ingest_venda', { p: parseHotmart(body, lp, rawId) });
        break;
      }
      case 'kiwify':
        resultado = await db.rpc('ingest_venda', { p: parseKiwify(body, lp, rawId) }); break;
      case 'herospark':
        resultado = await db.rpc('ingest_venda', { p: parseHerospark(body, lp, rawId) }); break;
      case 'tmb':
        resultado = await db.rpc('ingest_venda', { p: parseTMB(body, lp, rawId) }); break;
      case 'tmb-financeiro': {
        // avisa parcela a parcela; só somamos no total pago do pedido
        const itens = Array.isArray(body) ? body : [body];
        resultado = await db.rpc('ingest_pagamentos', { p: { itens } });
        break;
      }
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
// WIDGET DA LP — /embed.js?l=slug
// O cliente cola duas linhas na landing:
//   <div id="pd-captura"></div>
//   <script src=".../embed.js?l=lanc-2026-09"></script>
//
// O widget faz captura e quiz na MESMA página, trocando de seção sem
// recarregar. Como as perguntas vêm da API em tempo real, mexer no quiz
// pela dash muda a página do cliente sem tocar no código dele.
// =====================================================================
function widgetJS(slug: string, base: string, paginaQuiz = ''): string {
  return `(function(){
  var LANC = ${JSON.stringify(slug)};
  var API  = ${JSON.stringify(base)};
  var QUIZ_URL = ${JSON.stringify(paginaQuiz)};
  var alvo = document.getElementById('pd-captura');
  if(!alvo) { console.warn('[dash] falta <div id="pd-captura"></div>'); return; }

  var cfg = alvo.dataset || {};
  var COR = {
    dourado: cfg.dourado || '#FDE296',
    douradoEscuro: cfg.douradoEscuro || '#DAA520',
    verde1: cfg.verde1 || '#00DE00',
    verde2: cfg.verde2 || '#009500',
    menta: cfg.menta || '#8fd8ab',
    botao: cfg.textoBotao || 'QUERO PARTICIPAR DA AULA GRATUITA'
  };

  // ---------- estilo (escopado no widget) ----------
  var css = document.createElement('style');
  css.textContent = [
    '#pd-captura{--pd-dourado:'+COR.dourado+';--pd-dourado-escuro:'+COR.douradoEscuro+';',
    '--pd-verde1:'+COR.verde1+';--pd-verde2:'+COR.verde2+';--pd-menta:'+COR.menta+';',
    "--pd-sans:'Jost',-apple-system,BlinkMacSystemFont,sans-serif;",
    'width:100%;max-width:520px;margin-inline:auto;font-family:var(--pd-sans);color:#fff;text-align:left}',
    '#pd-captura *{box-sizing:border-box}',
    '#pd-captura .pd-sr{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}',
    '#pd-captura .pd-campo,#pd-captura .pd-linha{margin-bottom:6px}',
    '#pd-captura input,#pd-captura select,#pd-captura textarea{display:block;width:100%;height:38px;padding:0 10px;',
    'font-size:14px;color:#fff;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.35);',
    'border-radius:6px;outline:none;font-family:var(--pd-sans);transition:border-color .2s,box-shadow .2s,background .2s}',
    '#pd-captura textarea{height:auto;min-height:104px;padding:12px 14px;line-height:1.5;resize:vertical}',
    '#pd-captura input::placeholder,#pd-captura textarea::placeholder{color:rgba(255,255,255,.7)}',
    '#pd-captura input:focus,#pd-captura select:focus,#pd-captura textarea:focus{border-color:var(--pd-menta);',
    'box-shadow:0 0 0 3px rgba(143,216,171,.25);background:rgba(0,0,0,.42)}',
    '#pd-captura input.pd-ruim{border-color:#ff6b6b;box-shadow:0 0 0 3px rgba(255,107,107,.18)}',
    '#pd-captura .pd-linha{display:flex;gap:8px;align-items:center}',
    '#pd-captura .pd-ddi{min-width:92px;max-width:104px;appearance:none;padding-right:22px;',
    'background-image:linear-gradient(45deg,transparent 50%,#fff 50%),linear-gradient(135deg,#fff 50%,transparent 50%);',
    'background-position:right 10px top 16px,right 6px top 16px;background-size:6px 6px;background-repeat:no-repeat}',
    '#pd-captura .pd-tel{flex:1}',
    '#pd-captura .pd-btn{width:100%;padding:12px 18px;margin-top:8px;font-size:14px;font-weight:800;',
    'text-transform:uppercase;color:#fff;border:none;border-radius:10px;cursor:pointer;line-height:1.3;',
    'font-family:var(--pd-sans);background:linear-gradient(90deg,var(--pd-verde1) 0%,var(--pd-verde2) 100%)}',
    '#pd-captura .pd-btn:hover:not(:disabled){filter:brightness(1.06)}',
    '#pd-captura .pd-btn:disabled{opacity:.65;cursor:default}',
    '#pd-captura .pd-erro{display:none;margin-top:10px;padding:9px 12px;border-radius:8px;',
    'background:rgba(255,107,107,.12);border:1px solid rgba(255,107,107,.4);color:#ffb3b3;font-size:13px;text-align:center}',
    '#pd-captura .pd-erro.on{display:block}',
    '#pd-captura .pd-barra{height:5px;background:rgba(255,255,255,.14);border-radius:99px;overflow:hidden;margin-bottom:18px}',
    '#pd-captura .pd-barra i{display:block;height:100%;width:0;border-radius:99px;',
    'background:linear-gradient(90deg,var(--pd-dourado-escuro),var(--pd-dourado));transition:width .35s cubic-bezier(.4,0,.2,1)}',
    '#pd-captura .pd-passo{font-size:11.5px;color:var(--pd-dourado);font-weight:600;letter-spacing:.1em;text-transform:uppercase;margin-bottom:8px}',
    '#pd-captura .pd-pergunta{font-size:20px;font-weight:700;line-height:1.3;margin:0 0 6px}',
    '#pd-captura .pd-ajuda{font-size:14px;color:rgba(255,255,255,.78);margin-bottom:16px}',
    '#pd-captura .pd-opcoes{display:flex;flex-direction:column;gap:8px}',
    '#pd-captura .pd-opcao{display:flex;align-items:center;gap:12px;padding:14px 15px;background:rgba(0,0,0,.35);',
    'border:1px solid rgba(255,255,255,.22);border-radius:8px;cursor:pointer;font-size:15px;color:#fff;',
    'text-align:left;width:100%;font-family:var(--pd-sans);transition:border-color .18s,background .18s}',
    '#pd-captura .pd-opcao:hover{border-color:rgba(255,255,255,.45);background:rgba(0,0,0,.45)}',
    '#pd-captura .pd-opcao.sel{border-color:var(--pd-dourado);background:rgba(253,226,150,.1)}',
    '#pd-captura .pd-marca{width:20px;height:20px;border-radius:50%;border:1.5px solid rgba(255,255,255,.45);flex-shrink:0;display:grid;place-items:center}',
    '#pd-captura .pd-opcao.sel .pd-marca{border-color:var(--pd-dourado)}',
    '#pd-captura .pd-opcao.sel .pd-marca::after{content:"";width:9px;height:9px;border-radius:50%;background:var(--pd-dourado)}',
    '#pd-captura .pd-voltar{background:none;border:none;color:rgba(255,255,255,.5);font-size:13.5px;',
    'cursor:pointer;font-family:var(--pd-sans);padding:10px 2px 0;font-weight:500}',
    '#pd-captura .pd-voltar:hover{color:var(--pd-dourado)}',
    '#pd-captura .pd-fim{text-align:center;padding:12px 0}',
    '#pd-captura .pd-fim .pd-emoji{font-size:44px;margin-bottom:10px}',
    '#pd-captura .pd-fim h3{font-size:22px;font-weight:700;color:var(--pd-dourado);margin:0 0 8px}',
    '#pd-captura .pd-fim p{color:rgba(255,255,255,.78);font-size:15px;margin-bottom:20px}',
    '#pd-captura .pd-fim a{color:var(--pd-dourado)}',
    '#pd-captura .pd-fade{animation:pdFade .28s ease}',
    '@keyframes pdFade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}',
    '@media(max-width:600px){#pd-captura .pd-linha{gap:6px}#pd-captura .pd-ddi{min-width:72px;max-width:85px}',
    '#pd-captura .pd-pergunta{font-size:18.5px}}'
  ].join('');
  document.head.appendChild(css);

  // ---------- rastreio ----------
  var CAMPOS = ['utm_source','utm_medium','utm_campaign','utm_content','utm_term',
                'cid','aid','adid','fbclid','sck','gclid'];
  var trk = {};
  var qs = new URLSearchParams(location.search);
  CAMPOS.forEach(function(c){
    var v = qs.get(c);
    if(!v){ try{ v = sessionStorage.getItem('trk_'+c); }catch(e){} }
    if(v){ trk[c] = v; try{ sessionStorage.setItem('trk_'+c, v); }catch(e){} }
  });

  // bandeira, DDI e formato do número. A máscara usa 0 como dígito.
  var PAISES = [
    {ddi:'55',  bandeira:'\uD83C\uDDE7\uD83C\uDDF7', mascara:'(00) 00000-0000'},
    {ddi:'1',   bandeira:'\uD83C\uDDFA\uD83C\uDDF8', mascara:'(000) 000-0000'},
    {ddi:'351', bandeira:'\uD83C\uDDF5\uD83C\uDDF9', mascara:'000 000 000'},
    {ddi:'34',  bandeira:'\uD83C\uDDEA\uD83C\uDDF8', mascara:'000 000 000'},
    {ddi:'39',  bandeira:'\uD83C\uDDEE\uD83C\uDDF9', mascara:'000 000 0000'},
    {ddi:'44',  bandeira:'\uD83C\uDDEC\uD83C\uDDE7', mascara:'00000 000000'},
    {ddi:'49',  bandeira:'\uD83C\uDDE9\uD83C\uDDEA', mascara:'0000 0000000'},
    {ddi:'54',  bandeira:'\uD83C\uDDE6\uD83C\uDDF7', mascara:'(00) 0000-0000'},
    {ddi:'56',  bandeira:'\uD83C\uDDE8\uD83C\uDDF1', mascara:'0 0000 0000'},
    {ddi:'57',  bandeira:'\uD83C\uDDE8\uD83C\uDDF4', mascara:'000 000 0000'},
    {ddi:'58',  bandeira:'\uD83C\uDDFB\uD83C\uDDEA', mascara:'000-0000000'},
    {ddi:'595', bandeira:'\uD83C\uDDF5\uD83C\uDDFE', mascara:'000 000000'},
    {ddi:'598', bandeira:'\uD83C\uDDFA\uD83C\uDDFE', mascara:'0 000 0000'},
    {ddi:'244', bandeira:'\uD83C\uDDE6\uD83C\uDDF4', mascara:'000 000 000'},
    {ddi:'258', bandeira:'\uD83C\uDDF2\uD83C\uDDFF', mascara:'00 000 0000'},
    {ddi:'61',  bandeira:'\uD83C\uDDE6\uD83C\uDDFA', mascara:'000 000 000'},
    {ddi:'81',  bandeira:'\uD83C\uDDEF\uD83C\uDDF5', mascara:'00 0000 0000'}
  ];

  var inicio = Date.now();
  var inscricaoId = window.__pdInscricao || null;

  // Na página do quiz o lead já foi capturado: não há formulário a
  // mostrar, só as perguntas.
  var SO_QUIZ = !!window.__pdSoQuiz;

  // Endereço da página de quiz. Por padrão é a que o próprio Worker
  // serve; um endereço próprio no lançamento substitui.
  var PAGINA_QUIZ = (function(){
    if(SO_QUIZ) return '';
    try{
      var s = document.currentScript
              || document.querySelector('script[src*="embed.js"]');
      return (s && s.getAttribute('data-quiz')) || QUIZ_URL || (API + '/q');
    }catch(e){ return QUIZ_URL || (API + '/q'); }
  })();
  var perguntas = [], visiveis = [], respostas = {}, atual = 0, grupoUrl = null;

  function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;'); }
  function pinta(html){ alvo.innerHTML = '<div class="pd-fade">'+html+'</div>'; }

  // ---------- formulário ----------
  function telaForm(){
    pinta(
      '<div class="pd-campo"><label for="pd-nome" class="pd-sr">Nome</label>'
      + '<input id="pd-nome" type="text" placeholder="Insira seu nome" autocomplete="name"></div>'
      + '<div class="pd-campo"><label for="pd-email" class="pd-sr">E-mail</label>'
      + '<input id="pd-email" type="email" placeholder="Seu melhor Email" autocomplete="email" '
      + 'inputmode="email" spellcheck="false" autocapitalize="off"></div>'
      + '<div class="pd-linha"><label for="pd-ddi" class="pd-sr">DDI</label>'
      + '<select id="pd-ddi" class="pd-ddi">'
      + PAISES.map(function(p,i){
          return '<option value="'+p.ddi+'" data-mascara="'+p.mascara+'"'+(i===0?' selected':'')
               + '>'+p.bandeira+' +'+p.ddi+'</option>';
        }).join('')
      + '</select><label for="pd-tel" class="pd-sr">WhatsApp</label>'
      + '<input id="pd-tel" type="tel" maxlength="19" placeholder="(00) 00000-0000" class="pd-tel" '
      + 'autocomplete="tel" inputmode="tel"></div>'
      + '<div class="pd-sr" aria-hidden="true"><input id="pd-empresa" type="text" tabindex="-1" autocomplete="off"></div>'
      + '<button type="button" id="pd-enviar" class="pd-btn">'+esc(COR.botao)+'</button>'
      + '<div class="pd-erro" id="pd-erro"></div>'
    );

    var nome = q('pd-nome'), email = q('pd-email'), tel = q('pd-tel'), ddi = q('pd-ddi');

    [nome, email, tel].forEach(function(c){
      c.addEventListener('input', function(){ c.classList.remove('pd-ruim'); q('pd-erro').classList.remove('on'); });
      c.addEventListener('keydown', function(ev){ if(ev.key === 'Enter') enviarForm(); });
    });

    function mascaraAtual(){
      var op = ddi.options[ddi.selectedIndex];
      return (op && op.dataset.mascara) || '(00) 00000-0000';
    }

    /** Aplica o formato do país escolhido, dígito a dígito. */
    function formatar(valor, molde){
      var d = valor.replace(/\\D/g,'');

      // Brasil tem dois formatos: fixo (10 dígitos) e celular (11)
      if(ddi.value === '55'){
        // O celular preenche sozinho com o número completo, incluindo o
        // 55 do país. Cortar em 11 dígitos direto come os dois últimos
        // do número — o lead entra no grupo com um telefone e fica
        // salvo com outro, e nunca mais casa.
        //
        // 13 dígitos começando com 55 é DDI + DDD + 9 dígitos: o 55 sai.
        if(d.length === 13 && d.slice(0,2) === '55'){
          d = d.slice(2);
        } else if(d.length === 12 && d.slice(0,2) === '55'){
          // 12 dígitos com 55 na frente é DDI + DDD + 8 dígitos.
          //
          // O 55 também é DDD (Santa Maria), então "555599887766" pode
          // ser DDI+DDD 55 ou DDD 55 + 10 dígitos. Doze dígitos não
          // cabem num número brasileiro sem DDI, então o primeiro 55
          // é sempre o país.
          d = d.slice(2);
        }

        d = d.slice(0, 11);
        molde = d.length <= 10 ? '(00) 0000-0000' : '(00) 00000-0000';
      }

      var limite = (molde.match(/0/g) || []).length;
      d = d.slice(0, limite);
      var saida = '', i = 0;
      for(var k = 0; k < molde.length && i < d.length; k++){
        saida += molde[k] === '0' ? d[i++] : molde[k];
      }
      return saida;
    }

    tel.addEventListener('input', function(e){
      e.target.value = formatar(e.target.value, mascaraAtual());
    });

    // troca de país refaz o formato e o exemplo
    ddi.addEventListener('change', function(){
      var m = mascaraAtual();
      tel.placeholder = m;
      tel.value = formatar(tel.value, m);
      tel.classList.remove('pd-ruim');
    });

    q('pd-enviar').addEventListener('click', enviarForm);
  }

  function q(id){ return document.getElementById(id); }

  function erroForm(msg){
    var e = q('pd-erro');
    if(e){ e.textContent = msg; e.classList.add('on'); }
    var b = q('pd-enviar');
    if(b){ b.disabled = false; b.textContent = COR.botao; }
  }

  async function enviarForm(){
    var nome = q('pd-nome'), email = q('pd-email'), tel = q('pd-tel'), ddi = q('pd-ddi');
    q('pd-erro').classList.remove('on');

    var vNome = nome.value.trim(), vEmail = email.value.trim(), vTel = tel.value.replace(/\\D/g,'');
    var ruim = false;
    if(vNome.length < 2){ nome.classList.add('pd-ruim'); ruim = true; }
    if(!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$/.test(vEmail)){ email.classList.add('pd-ruim'); ruim = true; }
    var minimo = ddi.value === '55' ? 10 : 6;
    if(vTel.length < minimo){ tel.classList.add('pd-ruim'); ruim = true; }
    if(ruim){ erroForm('Confira os campos destacados para continuar.'); return; }

    var b = q('pd-enviar');
    b.disabled = true; b.textContent = 'ENVIANDO…';

    var corpo = Object.assign({}, trk, {
      nome: vNome, email: vEmail,
      telefone: ddi.value === '55' ? vTel : ddi.value + vTel,
      ddi: ddi.value,
      empresa: q('pd-empresa').value,
      lancamento: LANC,
      formulario: 'lp-embed',
      pagina_origem: location.href,
      tempo_ms: Date.now() - inicio
    });

    try{
      var r = await fetch(API + '/captura', {
        method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(corpo)
      });
      var d = await r.json();
      if(!d.ok){ erroForm(d.erro || 'Não foi possível concluir. Tente novamente.'); return; }

      inscricaoId = d.inscricao_id || null;
      if(typeof fbq === 'function'){ try{ fbq('track','Lead'); }catch(e){} }
      if(window.dataLayer){ try{ window.dataLayer.push({event:'lead_capturado'}); }catch(e){} }

      // O quiz vai para uma página só dele: na landing ele disputa
      // atenção com o resto do conteúdo, e o lead abandona no meio.
      // Sem página de quiz configurada, continua na mesma tela.
      if(PAGINA_QUIZ){
        var destino = PAGINA_QUIZ
          + (PAGINA_QUIZ.indexOf('?') === -1 ? '?' : '&')
          + 'l=' + encodeURIComponent(LANC)
          + (inscricaoId ? '&i=' + encodeURIComponent(inscricaoId) : '');
        window.location.href = destino;
        return;
      }

      alvo.scrollIntoView({behavior:'smooth', block:'center'});
      iniciarQuiz();
    }catch(e){
      erroForm('Falha de conexão. Verifique sua internet e tente de novo.');
    }
  }

  // ---------- quiz, na mesma página ----------
  async function iniciarQuiz(){
    pinta('<div class="pd-fim"><p>Só mais um passo…</p></div>');
    try{
      var r = await fetch(API + '/quiz?l=' + encodeURIComponent(LANC));
      var d = await r.json();
      if(!d.ok || !d.perguntas || !d.perguntas.length){ finalizar(); return; }
      perguntas = d.perguntas;
      recalcular();
      var intro = d.intro || {};
      if(intro.titulo || intro.texto) telaIntro(intro); else desenhar();
    }catch(e){ finalizar(); }
  }

  function telaIntro(intro){
    pinta(
      '<div class="pd-fim" style="text-align:left">'
      + '<h3 style="font-size:24px;margin-bottom:12px">'+esc(intro.titulo || 'Falta pouco')+'</h3>'
      + (intro.texto ? '<p style="text-align:left">'+esc(intro.texto)+'</p>' : '')
      + '<button type="button" class="pd-btn" id="pd-comecar">'+esc(intro.botao || 'Responder')+'</button></div>'
    );
    q('pd-comecar').addEventListener('click', function(){ atual = 0; desenhar(); });
  }

  function cabe(p){
    if(!p.condicao || !p.condicao.chave) return true;
    var dada = respostas[p.condicao.chave];
    if(dada == null) return false;
    return (p.condicao.valores || []).indexOf(dada) !== -1;
  }
  function recalcular(){ visiveis = perguntas.filter(cabe); }

  function desenhar(){
    recalcular();
    if(atual >= visiveis.length){ enviarQuiz(); return; }

    var p = visiveis[atual];
    var pct = (atual / visiveis.length) * 100;

    var corpo;
    if(p.tipo === 'texto'){
      corpo = '<textarea id="pd-texto" placeholder="Escreva aqui...">'+esc(respostas[p.chave]||'')+'</textarea>'
            + '<button type="button" class="pd-btn" id="pd-avancar">Avançar</button>';
    } else {
      corpo = '<div class="pd-opcoes">'
        + (p.opcoes||[]).map(function(o){
            var sel = respostas[p.chave] === o.valor ? ' sel' : '';
            return '<button type="button" class="pd-opcao'+sel+'" data-valor="'+esc(o.valor)+'">'
                 + '<span class="pd-marca"></span><span>'+esc(o.label)+'</span></button>';
          }).join('')
        + '</div>';
    }

    pinta(
      '<div class="pd-barra"><i style="width:'+pct+'%"></i></div>'
      + '<div class="pd-passo">Pergunta '+(atual+1)+' de '+visiveis.length+'</div>'
      + '<p class="pd-pergunta">'+esc(p.enunciado)+'</p>'
      + (p.ajuda ? '<div class="pd-ajuda">'+esc(p.ajuda)+'</div>' : '')
      + corpo
      + '<div class="pd-erro" id="pd-erro">Responda para continuar</div>'
      + (atual > 0 ? '<button type="button" class="pd-voltar" id="pd-voltar">← Voltar</button>' : '')
    );

    if(p.tipo === 'texto'){
      q('pd-avancar').addEventListener('click', function(){
        var v = (q('pd-texto').value || '').trim();
        if(p.obrigatoria && !v){ q('pd-erro').classList.add('on'); return; }
        respostas[p.chave] = v; atual++; desenhar();
      });
    } else {
      Array.prototype.forEach.call(alvo.querySelectorAll('.pd-opcao'), function(b){
        b.addEventListener('click', function(){
          respostas[p.chave] = b.dataset.valor;
          b.classList.add('sel');
          recalcular();
          setTimeout(function(){ atual++; desenhar(); }, 240);
        });
      });
    }

    var voltar = q('pd-voltar');
    if(voltar) voltar.addEventListener('click', function(){ if(atual>0){ atual--; desenhar(); } });
  }

  async function enviarQuiz(){
    pinta('<div class="pd-fim"><p>Salvando suas respostas…</p></div>');
    try{
      var r = await fetch(API + '/quiz', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({ inscricao_id: inscricaoId, lancamento: LANC, respostas: respostas })
      });
      var d = await r.json();
      grupoUrl = d.grupo_url || null;
    }catch(e){}
    finalizar();
  }

  function finalizar(){
    if(!grupoUrl){
      grupoUrl = API + '/r/grupo/publico?l=' + encodeURIComponent(LANC)
               + (inscricaoId ? '&i=' + inscricaoId : '');
    }
    pinta(
      '<div class="pd-barra"><i style="width:100%"></i></div>'
      + '<div class="pd-fim"><div class="pd-emoji">✅</div>'
      + '<h3>Inscrição confirmada!</h3>'
      + '<p>Entre no grupo do WhatsApp para receber o link da aula e os avisos.</p>'
      + '<a class="pd-btn" style="display:block;text-decoration:none" href="'+esc(grupoUrl)+'">💬 Entrar no grupo</a></div>'
    );
    setTimeout(function(){ try{ window.location.href = grupoUrl; }catch(e){} }, 900);
  }

  // Na página do quiz o lead já foi capturado: mostrar o formulário de
  // novo faria ele preencher duas vezes e criaria lead duplicado.
  if(SO_QUIZ){
    if(inscricaoId){
      iniciarQuiz();
    } else {
      // chegou na página sem passar pela captura
      pinta(
        '<div class="pd-fim"><div class="pd-emoji">👋</div>'
        + '<h3>Comece pela inscrição</h3>'
        + '<p>Preencha o formulário na página de inscrição para responder '
        + 'as perguntas.</p></div>'
      );
    }
  } else {
    telaForm();
  }
})();`;
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

  // Só anúncio de campanha de CAPTAÇÃO entra no custo.
  //
  // Uma campanha de engajamento com o código do lançamento no nome
  // somava ao investimento e piorava o CPL de todo mundo: o gasto
  // entrava e os leads não, porque engajamento não traz lead.
  //
  // Engajamento e remarketing têm o seu papel; só não contam no custo
  // por lead da captação.
  const semAcento = (s: string) => s
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase();

  const campanhasDeCaptacao = new Set(
    campanhas
      .filter((c: any) => semAcento(String(c.name || '')).includes('CAPTACAO'))
      .map((c: any) => c.id),
  );

  const conjuntoParaCampanha = new Map(
    conjuntos.map((a: any) => [a.id, a.campaign_id]),
  );

  const idsAnuncio = new Set(
    anuncios
      .filter((a: any) => {
        // sem campanha identificada, deixa passar: melhor contar um
        // gasto a mais do que perder o de um anúncio válido
        const camp = conjuntoParaCampanha.get(a.adset_id);
        if (!camp) return true;
        return campanhasDeCaptacao.has(camp);
      })
      .map((a: any) => a.id),
  );

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
    // O erro em singular é o que o cron grava. Sem ele, 95 falhas
    // foram registradas como "undefined" — o que não diz nada e
    // esconde justamente o motivo de o gasto não estar chegando.
    erro: erros.length >= contas.length
      ? erros.map((e: any) => typeof e === 'string' ? e : JSON.stringify(e)).join(' | ')
      : undefined,
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
// SEGREDOS DAS INTEGRAÇÕES
// Ficam no banco para o cliente configurar pela tela. O secret do Worker
// continua valendo como reserva, caso o banco não responda.
// =====================================================================
const cacheSegredo = new Map<string, { ate: number; dados: any }>();

async function segredoIntegracao(slug: string, chave: string, db: Supabase): Promise<any> {
  const id = slug + ':' + chave;
  const agora = Date.now();
  const guardado = cacheSegredo.get(id);
  if (guardado && guardado.ate > agora) return guardado.dados;

  let dados: any = { ativa: false };
  try {
    dados = await db.rpc('integracao_segredo', { p: { slug, chave } });
  } catch { /* banco fora: usa o valor do Worker */ }

  cacheSegredo.set(id, { ate: agora + 60 * 1000, dados });
  if (cacheSegredo.size > 100) cacheSegredo.clear();
  return dados;
}

// =====================================================================
// TMB EDUCAÇÃO
// Não manda webhook: a dash consulta a API dela de tempos em tempos.
// O retorno já traz UTM de primeiro e último toque, o que dá atribuição
// mesmo para quem comprou sem passar pela nossa captação.
// =====================================================================
async function sincronizarTMB(dias: number, db: Supabase, env: Env): Promise<any> {
  const cfg = await segredoIntegracao('tmb', 'token', db);
  const token = (cfg?.ativa && cfg?.valor) || env.TMB_TOKEN;
  if (!token) return { ok: false, erro: 'token da TMB nao configurado' };

  const produtoId = cfg?.config?.produto_id || '';
  const ate = new Date();
  const de = new Date(ate.getTime() - dias * 86400000);
  const fmt = (d: Date) => d.toISOString().slice(0, 10);

  let pagina = 1;
  let total = 0;
  const pedidos: any[] = [];

  // paginação: para quando a página vier menor que o tamanho pedido
  while (pagina <= 20) {
    const qs = new URLSearchParams({
      pageNumber: String(pagina),
      pageSize: '100',
      data_inicio: fmt(de),
      data_final: fmt(ate),
    });
    if (produtoId) qs.set('produto_id', String(produtoId));

    const r = await fetch(`https://api.tmbeducacao.com.br/api/pedidos?${qs}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!r.ok) {
      return { ok: false, erro: `tmb ${r.status}: ${(await r.text()).slice(0, 200)}` };
    }

    const d: any = await r.json().catch(() => null);
    const lote: any[] = Array.isArray(d) ? d : (d?.data || d?.items || (d ? [d] : []));
    if (!lote.length) break;

    pedidos.push(...lote);
    if (lote.length < 100) break;
    pagina++;
  }

  for (const p of pedidos) {
    const bruto = Number(p.valor_total || 0);
    const taxa = Number(p.taxa_administracao || 0);
    const situacao = String(p.status_pedido || '').toLowerCase();

    const status = situacao.includes('efetiv') ? 'aprovada'
                 : situacao.includes('cancel') ? 'cancelada'
                 : situacao.includes('reembols') ? 'reembolsada'
                 : 'pendente';

    try {
      await db.rpc('ingest_venda', {
        p: {
          // a TMB não diz o lançamento; a venda entra no ativo e pode
          // ser movida depois em Ajustes se cair no lugar errado
          lancamento: await slugAtivo(db, env),
          plataforma: 'tmb',
          transacao_id: String(p.pedido_id ?? ''),
          produto: p.lancamento || p.produto_nome || null,
          oferta: p.produto_id ? String(p.produto_id) : null,
          status,
          metodo: 'financiamento',
          parcelas: p.parcelas ?? null,
          valor_bruto: bruto,
          valor_liquido: taxa > 0 ? Number((bruto * (1 - taxa / 100)).toFixed(2)) : 0,
          moeda: 'BRL',
          email: p.email || null,
          telefone: p.telefone || null,
          src: p.utm_source || null,
          ocorreu_em: p.data_efetivado || p.criado_em || null,
          raw: p,
        },
      });
      total++;
    } catch { /* um pedido torto não derruba o lote */ }
  }

  await db.rpc('reconciliar_vendas', { p: {} }).catch(() => {});
  return { ok: true, pedidos: pedidos.length, gravados: total };
}

// =====================================================================
// GASTO DOS LANÇAMENTOS ANTIGOS
//
// A sincronização normal filtra campanhas pelo código no nome. Nos
// lançamentos antigos esse código não existe, mas a planilha de captura
// trouxe o ID de cada anúncio — e por ID a API responde sem depender de
// nome nenhum.
// =====================================================================
async function sincronizarHistorico(slug: string, db: Supabase, env: Env): Promise<any> {
  if (!env.META_TOKEN) return { ok: false, erro: 'META_TOKEN nao configurado' };

  const plano = await db.rpc('ads_para_buscar', { p: { lancamento: slug } });
  if (plano?.ok === false) return plano;

  const ids: string[] = plano?.ad_ids || [];
  const contas: string[] = plano?.contas || [];
  if (!ids.length) return { ok: true, aviso: 'nenhum anuncio sem gasto', anuncios: 0 };
  if (!contas.length) {
    return { ok: false, erro: 'nenhuma conta de anuncio configurada em Ajustes' };
  }

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  const periodo = JSON.stringify({ since: plano.de, until: plano.ate });

  const itens: any[] = [];
  const erros: string[] = [];

  for (const conta of contas) {
    // a API aceita filtrar por lista de ids; 50 por vez evita URL gigante
    for (let i = 0; i < ids.length; i += 50) {
      const lote = ids.slice(i, i + 50);
      const qs = new URLSearchParams({
        level: 'ad',
        time_range: periodo,
        time_increment: '1',
        fields: 'ad_id,ad_name,adset_id,adset_name,campaign_id,campaign_name,'
              + 'spend,impressions,clicks,inline_link_clicks,date_start',
        filtering: JSON.stringify([{ field: 'ad.id', operator: 'IN', value: lote }]),
        limit: '500',
        access_token: env.META_TOKEN,
      });

      let url: string | null =
        `https://graph.facebook.com/${versao}/${conta}/insights?${qs}`;
      let paginas = 0;

      while (url && paginas < 20) {
        const r = await fetch(url);
        const d: any = await r.json().catch(() => ({}));

        if (d.error) {
          erros.push(`${conta}: ${d.error.message}`);
          break;
        }

        for (const linha of d.data || []) {
          itens.push({
            ad_id: linha.ad_id,
            nome: linha.ad_name,
            conjunto_id: linha.adset_id,
            conjunto: linha.adset_name,
            campanha_id: linha.campaign_id,
            campanha: linha.campaign_name,
            conta,
            dia: linha.date_start,
            gasto: linha.spend,
            impressoes: linha.impressions,
            cliques: linha.clicks,
            cliques_link: linha.inline_link_clicks,
          });
        }

        url = d.paging?.next || null;
        paginas++;
      }
    }
  }

  if (!itens.length) {
    return {
      ok: false,
      erro: erros.length ? erros[0]
        : 'o Meta nao devolveu gasto para esses anuncios no periodo',
      anuncios_procurados: ids.length,
    };
  }

  // grava em lotes: um payload muito grande estoura o limite do Postgres
  let entidades = 0, insights = 0, gasto = 0;
  for (let i = 0; i < itens.length; i += 300) {
    const r = await db.rpc('ingest_ads_historico', {
      p: { lancamento: slug, itens: itens.slice(i, i + 300) },
    });
    entidades += r?.entidades || 0;
    insights += r?.insights || 0;
    gasto += Number(r?.gasto || 0);
  }

  return {
    ok: true,
    anuncios_procurados: ids.length,
    linhas: itens.length,
    entidades, insights,
    gasto: Number(gasto.toFixed(2)),
    periodo: { de: plano.de, ate: plano.ate },
    avisos: erros.length ? erros : undefined,
  };
}

// =====================================================================
// CAMPANHAS QUE GASTARAM NO PERÍODO DO LANÇAMENTO
//
// Busca tudo que rodou na janela, sem filtrar por nome. A escolha de
// quais pertencem ao lançamento fica com o usuário — no mesmo período
// costuma haver remarketing e outros funis.
// =====================================================================
async function buscarCampanhasPeriodo(slug: string, db: Supabase, env: Env): Promise<any> {
  if (!env.META_TOKEN) return { ok: false, erro: 'META_TOKEN nao configurado' };

  const plano = await db.rpc('campanhas_escolhidas', { p: { lancamento: slug } });
  if (plano?.ok === false) return plano;

  // as contas vêm do banco; a variável do Worker é a última reserva,
  // para o caso de alguém limpar o campo sem querer
  let contas: string[] = plano?.contas || [];
  if (!contas.length && env.META_CONTAS) {
    contas = env.META_CONTAS.split(',').map((c) => c.trim()).filter(Boolean);
  }
  if (!contas.length) {
    return {
      ok: false,
      erro: 'nenhuma conta de anuncio configurada. Preencha em Ajustes > Contas de anuncio.',
    };
  }
  if (!plano?.de) {
    return { ok: false, erro: 'este lancamento nao tem leads com data' };
  }

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  const periodo = JSON.stringify({ since: plano.de, until: plano.ate });
  const campanhas: any[] = [];
  const erros: string[] = [];

  for (const conta of contas) {
    const qs = new URLSearchParams({
      level: 'campaign',
      time_range: periodo,
      fields: 'campaign_id,campaign_name,spend,impressions,date_start,date_stop',
      limit: '200',
      access_token: env.META_TOKEN,
    });

    let url: string | null =
      `https://graph.facebook.com/${versao}/${conta}/insights?${qs}`;
    let paginas = 0;

    while (url && paginas < 10) {
      const r = await fetch(url);
      const d: any = await r.json().catch(() => ({}));
      if (d.error) { erros.push(`${conta}: ${d.error.message}`); break; }

      for (const linha of d.data || []) {
        campanhas.push({
          id: linha.campaign_id,
          nome: linha.campaign_name,
          conta,
          gasto: linha.spend,
          impressoes: linha.impressions,
          de: linha.date_start,
          ate: linha.date_stop,
        });
      }
      url = d.paging?.next || null;
      paginas++;
    }
  }

  if (!campanhas.length) {
    return {
      ok: false,
      erro: erros.length ? erros[0] : 'nenhuma campanha gastou nesse periodo',
      periodo: { de: plano.de, ate: plano.ate },
    };
  }

  const r = await db.rpc('ingest_candidatas', { p: { lancamento: slug, campanhas } });
  return { ...r, periodo: { de: plano.de, ate: plano.ate },
           avisos: erros.length ? erros : undefined };
}

// Depois da escolha: puxa os anúncios das campanhas marcadas.
async function importarCampanhasEscolhidas(
  slug: string, db: Supabase, env: Env,
): Promise<any> {
  if (!env.META_TOKEN) return { ok: false, erro: 'META_TOKEN nao configurado' };

  const plano = await db.rpc('campanhas_escolhidas', { p: { lancamento: slug } });
  const ids: string[] = plano?.ids || [];
  if (!ids.length) return { ok: false, erro: 'nenhuma campanha marcada' };

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  const periodo = JSON.stringify({ since: plano.de, until: plano.ate });
  const itens: any[] = [];
  const erros: string[] = [];

  for (const conta of (plano?.contas || [])) {
    for (let i = 0; i < ids.length; i += 25) {
      const lote = ids.slice(i, i + 25);
      const qs = new URLSearchParams({
        level: 'ad',
        time_range: periodo,
        time_increment: '1',
        fields: 'ad_id,ad_name,adset_id,adset_name,campaign_id,campaign_name,'
              + 'spend,impressions,clicks,inline_link_clicks,date_start',
        filtering: JSON.stringify([
          { field: 'campaign.id', operator: 'IN', value: lote },
        ]),
        limit: '500',
        access_token: env.META_TOKEN,
      });

      let url: string | null =
        `https://graph.facebook.com/${versao}/${conta}/insights?${qs}`;
      let paginas = 0;

      while (url && paginas < 30) {
        const r = await fetch(url);
        const d: any = await r.json().catch(() => ({}));
        if (d.error) { erros.push(`${conta}: ${d.error.message}`); break; }

        for (const l of d.data || []) {
          itens.push({
            ad_id: l.ad_id, nome: l.ad_name,
            conjunto_id: l.adset_id, conjunto: l.adset_name,
            campanha_id: l.campaign_id, campanha: l.campaign_name,
            conta, dia: l.date_start, gasto: l.spend,
            impressoes: l.impressions, cliques: l.clicks,
            cliques_link: l.inline_link_clicks,
          });
        }
        url = d.paging?.next || null;
        paginas++;
      }
    }
  }

  if (!itens.length) {
    return { ok: false, erro: erros.length ? erros[0] : 'nenhum anuncio com gasto' };
  }

  let entidades = 0, insights = 0, gasto = 0;
  for (let i = 0; i < itens.length; i += 300) {
    const r = await db.rpc('ingest_ads_historico', {
      p: { lancamento: slug, itens: itens.slice(i, i + 300) },
    });
    entidades += r?.entidades || 0;
    insights += r?.insights || 0;
    gasto += Number(r?.gasto || 0);
  }

  return {
    ok: true, campanhas: ids.length, linhas: itens.length,
    entidades, insights, gasto: Number(gasto.toFixed(2)),
    periodo: { de: plano.de, ate: plano.ate },
  };
}

// =====================================================================
// MANYCHAT DIRETO
//
// Substitui o intermediário do n8n. A lógica é a mesma que ele fazia:
// tenta criar o contato; se já existe, procura pelo telefone e usa o id
// que voltou. A tag é opcional — quando o fluxo do ManyChat dispara na
// criação do contato, ela não é necessária.
//
// Vantagem de estar aqui: a dash sabe se deu certo. No n8n, uma falha de
// autenticação passava em silêncio e o lead sumia sem aviso.
// =====================================================================
const MANYCHAT_API = 'https://api.manychat.com/fb';

async function manychatChamar(
  caminho: string, token: string, corpo: any, metodo = 'POST',
): Promise<any> {
  const cabecalho: Record<string, string> = {
    accept: 'application/json',
    Authorization: `Bearer ${String(token).replace(/^Bearer\s+/i, '')}`,
  };

  let url = `${MANYCHAT_API}${caminho}`;
  let opcoes: RequestInit = { method: metodo, headers: cabecalho };

  if (metodo === 'GET') {
    url += '?' + new URLSearchParams(corpo);
  } else {
    cabecalho['Content-Type'] = 'application/json';
    opcoes = { method: metodo, headers: cabecalho, body: JSON.stringify(corpo) };
  }

  try {
    const r = await fetch(url, opcoes);
    const d: any = await r.json().catch(() => ({}));
    return { http: r.status, ...d };
  } catch (e: any) {
    return { http: 0, status: 'error', message: String(e?.message || e) };
  }
}

/** O ManyChat quer o número só com dígitos, DDI incluso e sem o '+'. */
function foneManychat(fone: string): string {
  const d = String(fone || '').replace(/\D/g, '');
  if (!d) return '';
  return d.startsWith('55') ? d : `55${d}`;
}

/** Junta o motivo real do erro, que o ManyChat espalha em vários campos. */
function motivoManychat(r: any): string {
  const partes: string[] = [];
  if (r?.message) partes.push(String(r.message));

  const d = r?.details;
  if (Array.isArray(d?.messages)) {
    for (const m of d.messages) {
      partes.push(`${m.field || ''}: ${m.message || ''}`.trim());
    }
  } else if (d?.messages && typeof d.messages === 'object') {
    for (const [campo, msg] of Object.entries(d.messages)) {
      partes.push(`${campo}: ${JSON.stringify(msg)}`);
    }
  } else if (typeof d === 'string') {
    partes.push(d);
  }

  return partes.filter(Boolean).join(' | ') || `http ${r?.http ?? '?'}`;
}

/**
 * Cria ou encontra o contato no ManyChat e dispara o fluxo.
 *
 * Três coisas que a API do ManyChat impõe e não são óbvias:
 *
 * 1. Criar contato de WhatsApp por API vem BLOQUEADO por padrão. Retorna
 *    "Permission denied to import wa_id" — que a API embrulha num
 *    "Validation error" genérico. Só o suporte libera, por ticket.
 *
 * 2. Contato criado pelo canal WhatsApp não é encontrado nem por
 *    findBySystemField nem por findByCustomField no campo padrão. A
 *    saída conhecida é manter um campo personalizado espelho com o
 *    número e buscar por ele — era o que o fluxo do n8n fazia com o
 *    field_id fixo.
 *
 * 3. sendFlow só funciona em contato ativo. Contato recém-criado que
 *    nunca interagiu está inativo, e a mensagem tem que sair por
 *    automação com gatilho de tag, não pela API.
 */
async function enviarManychat(lead: any, cfg: any): Promise<any> {
  const token = cfg?.token || '';
  if (!token) return { ok: false, erro: 'token do ManyChat nao configurado' };

  const fone = foneManychat(lead.telefone || lead.phone);
  if (!fone) return { ok: false, erro: 'lead sem telefone' };

  const nome = String(lead.nome || lead.name || '').trim();
  const partes = nome.split(/\s+/).filter(Boolean);
  const primeiro = partes[0] || 'Lead';
  const ultimo = partes.length > 1 ? partes.slice(1).join(' ') : '';

  const passos: string[] = [];
  let id = '';
  let jaExistia = false;
  let resultado_optin = true;

  // ---- 1. procurar antes de criar
  //
  // Criar primeiro e tratar o erro funciona, mas gasta uma chamada e
  // enche o log de "já existe". Procurar antes é mais limpo.
  if (cfg?.field_id) {
    const achado = await manychatChamar(
      '/subscriber/findByCustomField', token,
      { field_id: String(cfg.field_id), field_value: fone }, 'GET',
    );
    const lista = achado?.data;
    if (Array.isArray(lista) && lista[0]?.id) id = String(lista[0].id);
    else if (lista?.id) id = String(lista.id);
    passos.push(`busca campo ${cfg.field_id}: ${id ? 'achou' : 'vazio'}`);
  }

  if (!id) {
    const achado = await manychatChamar(
      '/subscriber/findBySystemField', token, { phone: fone }, 'GET',
    );
    const lista = achado?.data;
    if (Array.isArray(lista) && lista[0]?.id) id = String(lista[0].id);
    else if (lista?.id) id = String(lista.id);
    passos.push(`busca phone: ${id ? 'achou' : 'vazio'}`);
  }

  jaExistia = !!id;

  // ---- 2. criar, se não achou
  if (!id) {
    // Para WhatsApp o mínimo é first_name, whatsapp_phone e
    // consent_phrase. Campo vazio faz o ManyChat recusar em vez de
    // ignorar, então só mandamos o que tem valor.
    // O opt-in é o que faz o contato nascer ativo. Sem optin_whatsapp o
    // contato entra sem consentimento registrado, e aí nem a automação
    // com gatilho de novo contato dispara — que é o caminho oficial:
    // gatilho "Novo contato" com as condições "Opted-in through API" e
    // "Opted-in for WhatsApp".
    const corpo: Record<string, any> = {
      first_name: primeiro,
      whatsapp_phone: fone,
      optin_whatsapp: true,
      has_opt_in_sms: true,
      consent_phrase: 'aceitou receber mensagens no formulario de inscricao',
    };
    if (ultimo) corpo.last_name = ultimo;
    if (lead.email) {
      corpo.email = String(lead.email);
      corpo.has_opt_in_email = true;
    }

    let criado = await manychatChamar('/subscriber/createSubscriber', token, corpo);

    // "This WhatsApp ID already exists" acontece quando o contato foi
    // criado entre a nossa busca e a criação — ou quando ele existe com
    // um formato de número que a busca não encontrou.
    //
    // Não é erro: o contato está lá. Buscar de novo e seguir custa uma
    // chamada e salva o lead, que senão nunca entra no fluxo.
    const jaExiste = JSON.stringify(criado?.details || criado?.message || '')
      .includes('already exists');

    if (!criado?.data?.id && jaExiste) {
      const achado = await manychatChamar(
        '/subscriber/findBySystemField', token, { phone: fone }, 'GET',
      ).catch(() => null);

      if (achado?.data?.id) {
        criado = achado;
      } else {
        // o ManyChat às vezes guarda sem o nono dígito
        const semNono = fone.replace(/^(\d{4})9(\d{8})$/, '$1$2');
        if (semNono !== fone) {
          const outro = await manychatChamar(
            '/subscriber/findBySystemField', token, { phone: semNono }, 'GET',
          ).catch(() => null);
          if (outro?.data?.id) criado = outro;
        }
      }
    }

    if (criado?.data?.id) {
      id = String(criado.data.id);
      passos.push('contato criado');
    } else {
      const motivo = motivoManychat(criado);

      // "Permission denied to import" é a trava de conta, não erro de
      // dados. Sem o suporte liberar, nenhum ajuste de payload resolve —
      // por isso a mensagem diz o que fazer.
      const bloqueado = /permission denied|import/i.test(motivo);

      const invalido = JSON.stringify(criado?.details || '')
        .includes('not a valid WhatsApp');

      if (invalido) {
        // O número não existe no WhatsApp. Guardamos qual é: sem isso
        // a mensagem de erro não ajuda a encontrar o lead.
        return {
          ok: false,
          telefone_invalido: true,
          telefone: fone,
          erro: `numero sem WhatsApp: ${fone}`,
        };
      }

      return {
        ok: false,
        erro: bloqueado
          ? `${motivo} — a criacao de contato por API esta bloqueada nesta conta. `
            + 'Abra um ticket em help.manychat.com pedindo para habilitar '
            + '"import contacts via API".'
          : motivo,
        enviado: corpo,
        resposta: criado,
        passos,
      };
    }
  }

  const resultado: any = {
    ok: true, subscriber_id: id, criado: !jaExistia, passos,
    optin: resultado_optin,
  };

  if (!resultado_optin) {
    passos.push('opt-in nao confirmado: o contato pode nao receber template');
  }

  // ---- 3. campo espelho com o número
  //
  // É o que permite encontrar o contato na próxima vez. Sem ele, cada
  // lead repetido vira uma tentativa de criação que falha.
  if (cfg?.campo_telefone) {
    await manychatChamar('/subscriber/setCustomFieldByName', token, {
      subscriber_id: id,
      field_name: cfg.campo_telefone,
      field_value: fone,
    });
  }

  // ---- 4. campo do lançamento
  if (cfg?.campo_lancamento && lead.lancamento) {
    await manychatChamar('/subscriber/setCustomFieldByName', token, {
      subscriber_id: id,
      field_name: cfg.campo_lancamento,
      field_value: String(lead.lancamento),
    });
  }

  // ---- 5. tag
  //
  // A tag é o único caminho que serve para os DOIS casos:
  //
  //   contato novo       o gatilho "Novo contato" também funciona
  //   contato existente  o gatilho de novo contato NUNCA dispara —
  //                      ele já existia. Só a tag alcança essa pessoa.
  //
  // Por isso aplicamos sempre, mesmo sem configuração: sem tag, todo
  // lead que já está no ManyChat entra e não recebe nada.
  const tagUsar = cfg?.tag || 'dash-lead';
  if (tagUsar) {
    let tag = await manychatChamar('/subscriber/addTagByName', token, {
      subscriber_id: id, tag_name: tagUsar,
    });

    // addTagByName exige tag existente; na primeira vez ela não existe
    if (tag?.status !== 'success') {
      await manychatChamar('/page/createTag', token, { name: tagUsar });
      tag = await manychatChamar('/subscriber/addTagByName', token, {
        subscriber_id: id, tag_name: tagUsar,
      });
    }

    // Contato que já existia pode ter a tag de um lançamento anterior.
    // Remover e aplicar de novo faz o gatilho disparar outra vez — sem
    // isso, quem já entrou no mês passado não recebe nada agora.
    if (jaExistia && tag?.status === 'success') {
      await manychatChamar('/subscriber/removeTagByName', token, {
        subscriber_id: id, tag_name: tagUsar,
      });
      tag = await manychatChamar('/subscriber/addTagByName', token, {
        subscriber_id: id, tag_name: tagUsar,
      });
    }

    resultado.tag_aplicada = tag?.status === 'success';
    resultado.tag = tagUsar;
    if (!resultado.tag_aplicada) resultado.aviso_tag = motivoManychat(tag);
    passos.push(`tag ${tagUsar}: ${resultado.tag_aplicada ? 'ok' : 'falhou'}`);
  }

  // ---- 6. fluxo, quando configurado
  if (cfg?.flow_ns) {
    const fluxo = await manychatChamar('/sending/sendFlow', token, {
      subscriber_id: id, flow_ns: cfg.flow_ns,
    });
    resultado.fluxo_disparado = fluxo?.status === 'success';

    if (!resultado.fluxo_disparado) {
      const motivo = motivoManychat(fluxo);

      if (/not active/i.test(motivo)) {
        // Regra do ManyChat: contato que nunca respondeu está inativo e
        // não aceita sendFlow. A saída é a tag — automação com gatilho
        // de tag consegue enviar template para contato inativo.
        resultado.aviso_fluxo = cfg?.tag
          ? `${motivo} — a tag "${cfg.tag}" foi aplicada e a automacao do `
            + 'ManyChat deve disparar por ela. Pode remover MANYCHAT_FLOW.'
          : `${motivo} — configure MANYCHAT_TAG e crie no ManyChat uma automacao `
            + 'com gatilho "tag aplicada". Contato criado por API nao aceita '
            + 'sendFlow nem gatilho de novo contato.';
      } else {
        resultado.aviso_fluxo = motivo;
      }
    }
    passos.push(`fluxo: ${resultado.fluxo_disparado ? 'ok' : 'falhou'}`);
  }

  return resultado;
}

// =====================================================================
// INVESTIMENTO DE TODOS OS LANÇAMENTOS, DE UMA VEZ
//
// Busca as campanhas na API do Meta e deixa o banco distribuir o gasto
// pelos lançamentos usando a data no nome. Serve tanto para preencher o
// histórico quanto para rodar no cron, semana a semana.
// =====================================================================
async function sincronizarInvestimento(
  db: Supabase, env: Env, opcoes: { de?: string; ate?: string; todas?: boolean } = {},
): Promise<any> {
  if (!env.META_TOKEN) return { ok: false, erro: 'META_TOKEN nao configurado' };

  const plano = await db.rpc('periodo_investimento', {
    p: { de: opcoes.de || '', ate: opcoes.ate || '' },
  });

  // as contas vêm do banco; a variável do Worker é a última reserva,
  // para o caso de alguém limpar o campo sem querer
  let contas: string[] = plano?.contas || [];
  if (!contas.length && env.META_CONTAS) {
    contas = env.META_CONTAS.split(',').map((c) => c.trim()).filter(Boolean);
  }
  if (!contas.length) {
    return {
      ok: false,
      erro: 'nenhuma conta de anuncio configurada. Preencha em Ajustes > Contas de anuncio.',
    };
  }

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  const periodo = JSON.stringify({ since: plano.de, until: plano.ate });
  const campanhas: any[] = [];
  const erros: string[] = [];

  // Busca em dois níveis, e o motivo importa:
  //
  // ANÚNCIO   é o que casa com o lead, porque a UTM traz {{ad.name}}.
  //           Mas o Meta não devolve linha de anúncio excluído — o
  //           gasto dele some do relatório por anúncio.
  //
  // CAMPANHA  traz o total de verdade, incluindo o que foi gasto em
  //           anúncio que não existe mais.
  //
  // Gravamos os anúncios e, no fim, a diferença de cada campanha como
  // um registro à parte. Assim o total bate com o gerenciador e o
  // casamento por criativo continua funcionando.
  const totalPorCampanha = new Map<string, { nome: string; gasto: number; dia: string }>();
  const somaDosAnuncios = new Map<string, number>();

  for (const conta of contas) {
    for (const nivel of ['ad', 'campaign'] as const) {
      const campos = nivel === 'ad'
        ? 'ad_id,ad_name,adset_id,adset_name,campaign_id,campaign_name,'
          + 'spend,impressions,clicks,date_start'
        : 'campaign_id,campaign_name,spend,impressions,clicks,date_start';

      const qs = new URLSearchParams({
        level: nivel,
        time_range: periodo,
        time_increment: '1',
        fields: campos,
        limit: '500',
        access_token: env.META_TOKEN,
      });

      let url: string | null =
        `https://graph.facebook.com/${versao}/${conta}/insights?${qs}`;
      let paginas = 0;

      while (url && paginas < 120) {
        const r = await fetch(url);
        const d: any = await r.json().catch(() => ({}));
        if (d.error) { erros.push(`${conta} (${nivel}): ${d.error.message}`); break; }

        for (const l of d.data || []) {
          if (nivel === 'ad') {
            campanhas.push({
              id: l.ad_id,
              nome: l.ad_name,
              campanha: l.campaign_name,
              campanha_id: l.campaign_id,
              conjunto: l.adset_name,
              conjunto_id: l.adset_id,
              conta,
              gasto: l.spend,
              impressoes: l.impressions,
              cliques: l.clicks,
              dia: l.date_start,
            });

            const chave = `${l.campaign_id}|${l.date_start}`;
            somaDosAnuncios.set(
              chave, (somaDosAnuncios.get(chave) || 0) + Number(l.spend || 0),
            );
          } else {
            const chave = `${l.campaign_id}|${l.date_start}`;
            totalPorCampanha.set(chave, {
              nome: l.campaign_name,
              gasto: Number(l.spend || 0),
              dia: l.date_start,
            });
          }
        }

        url = d.paging?.next || null;
        paginas++;
      }
    }
  }

  // o que a campanha gastou e nenhum anúncio reportou
  let resgatado = 0;
  for (const [chave, campanha] of totalPorCampanha) {
    const jaContado = somaDosAnuncios.get(chave) || 0;
    const sobra = campanha.gasto - jaContado;

    // centavos de arredondamento não viram registro
    if (sobra <= 0.5) continue;

    const [campanhaId, dia] = chave.split('|');
    campanhas.push({
      id: `resto-${campanhaId}-${dia}`,
      nome: `${campanha.nome} · anúncios encerrados`,
      campanha: campanha.nome,
      campanha_id: campanhaId,
      conta: contas[0],
      gasto: String(sobra),
      impressoes: '0',
      cliques: '0',
      dia,
    });
    resgatado += sobra;
  }

  if (!campanhas.length) {
    return {
      ok: false,
      erro: erros.length ? erros[0] : 'o Meta nao devolveu gasto nesse periodo',
      periodo: { de: plano.de, ate: plano.ate },
    };
  }

  // lotes: um payload de milhares de linhas estoura o limite do Postgres
  const total: any = {
    campanhas: 0, gasto: 0, fora_de_captacao: 0, sem_data_no_nome: 0,
  };
  const porLanc: Record<string, number> = {};

  for (let i = 0; i < campanhas.length; i += 400) {
    const r = await db.rpc('ingest_investimento', {
      p: {
        campanhas: campanhas.slice(i, i + 400),
        so_captacao: !opcoes.todas,
      },
    });
    total.campanhas += r?.campanhas || 0;
    total.gasto += Number(r?.gasto || 0);
    total.fora_de_captacao += r?.fora_de_captacao || 0;
    total.sem_data_no_nome += r?.sem_data_no_nome || 0;
    for (const [slug, valor] of Object.entries(r?.por_lancamento || {})) {
      porLanc[slug] = (porLanc[slug] || 0) + Number(valor);
    }
  }

  return {
    ok: true,
    ...total,
    gasto: Number(total.gasto.toFixed(2)),
    linhas: campanhas.length,
    // quanto veio de anúncio que não existe mais: se for alto, boa parte
    // do investimento não tem como ser atribuída a criativo
    gasto_de_anuncios_encerrados: Number(resgatado.toFixed(2)),
    periodo: { de: plano.de, ate: plano.ate },
    por_lancamento: porLanc,
    avisos: erros.length ? erros : undefined,
  };
}

/**
 * A Hotmart manda muito mais que venda no mesmo webhook: aluno abriu a
 * área de membros, terminou um módulo, assinatura trocou de plano. Nada
 * disso é compra, e tentar gravar como venda enche o log de erro e
 * esconde os problemas de verdade.
 *
 * Só evento que começa com PURCHASE é venda.
 */
const EVENTOS_VENDA_HOTMART = /^PURCHASE_/i;

function ehVendaHotmart(body: any): boolean {
  const evento = String(body?.event || body?.data?.event || '').trim();
  // sem campo de evento, é payload antigo (v1) — esses só traziam venda
  if (!evento) return true;
  return EVENTOS_VENDA_HOTMART.test(evento);
}

// =====================================================================
// RECUPERAÇÃO DE PAGAMENTO PENDENTE
//
// PIX e boleto gerados que ainda não foram pagos. O disparo vai pelos
// mesmos caminhos que o lead novo usa — SellFlux para e-mail, ManyChat
// para WhatsApp — então não há integração nova para configurar.
//
// Cada envio fica registrado. Quem recebeu nas últimas 24 horas não
// entra de novo, mesmo que você clique duas vezes.
// =====================================================================
// =====================================================================
// O DISPARO AUTOMÁTICO DE RECUPERAÇÃO FOI REMOVIDO
//
// Ele mandava o contato para o endpoint do SellFlux da CAPTAÇÃO e para
// o fluxo do ManyChat de quem acabou de entrar no lançamento. Os dois
// destinos existem para lead novo; recuperação passando por ali coloca
// quem tem boleto aberto na sequência de aquecimento. Já aconteceu uma
// vez com a reativação e não vai voltar a acontecer por um botão daqui.
//
// No lugar, a tela de Recuperação abre a conversa no WhatsApp com a
// mensagem pronta do motivo (rotas /api/mensagens-recuperacao e
// /api/contato-manual). Se um dia existirem endereços próprios de
// recuperação no SellFlux e no ManyChat, o automático volta — com
// destino separado, como a reativação tem hoje.
// =====================================================================



// =====================================================================
// PÁGINA DO QUIZ — /q?i=<inscricao>&l=<lancamento>
//
// O Worker serve a página inteira. Três motivos para não usar um
// arquivo separado no Pages:
//
//   não há endereço para configurar nem para errar
//   quem abre sem ter preenchido o formulário não vê pergunta nenhuma
//   o visual acompanha o que está salvo no lançamento, sem novo deploy
// =====================================================================
function paginaQuiz(slug: string, inscricao: string, base: string): string {
  return `<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Falta pouco</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Jost:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{
    background:#0B0A0A;
    background-image:radial-gradient(circle at 20% 0%, #1C1A19 0%, transparent 60%);
    color:#fff;font-family:Jost,system-ui,sans-serif;min-height:100vh;
    display:flex;align-items:center;justify-content:center;padding:22px;
    -webkit-font-smoothing:antialiased;
  }
  .caixa{width:100%;max-width:520px}
  #pd-captura{width:100%}
</style>
</head>
<body>
  <div class="caixa"><div id="pd-captura"></div></div>
  <script>
    // a página já sabe quem é o lead: o widget pula a captura e vai
    // direto para as perguntas
    window.__pdInscricao = ${JSON.stringify(inscricao)};
    window.__pdSoQuiz = true;
  <\/script>
  <script src="${base}/embed.js?l=${encodeURIComponent(slug)}"><\/script>
</body>
</html>`;
}


// =====================================================================
// UPLOAD DE IMAGEM PARA O R2
//
// O binding direto do R2 só funciona quando o bucket está na mesma
// conta Cloudflare do Worker. Como o bucket vive em outra conta,
// falamos com ele pela API S3, que é aberta a qualquer um com as
// credenciais certas.
//
// Isso exige assinar cada requisição no formato AWS SigV4 — não há
// biblioteca disponível no Worker, então a assinatura é feita aqui com
// as funções de criptografia que o próprio ambiente oferece.
// =====================================================================

const TIPOS_IMAGEM: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

const LIMITE_IMAGEM = 5 * 1024 * 1024;   // 5 MB

/** Bytes em hexadecimal minúsculo, como o SigV4 exige. */
function paraHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

async function sha256Hex(dados: ArrayBuffer | string): Promise<string> {
  const bytes = typeof dados === 'string' ? new TextEncoder().encode(dados) : dados;
  return paraHex(await crypto.subtle.digest('SHA-256', bytes));
}

async function hmac(chave: ArrayBuffer | Uint8Array, msg: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey(
    'raw', chave as any, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  return crypto.subtle.sign('HMAC', k, new TextEncoder().encode(msg));
}

/**
 * Assina e envia um PUT para o endpoint S3 do R2.
 *
 * A ordem dos passos importa: qualquer diferença de espaço, maiúscula
 * ou ordem de cabeçalho produz assinatura diferente e o R2 recusa com
 * SignatureDoesNotMatch, sem dizer onde está o erro.
 */
async function enviarParaR2(
  env: Env, caminho: string, corpo: ArrayBuffer, tipo: string,
): Promise<{ ok: boolean; erro?: string; status?: number }> {
  const conta = (env.R2_ACCOUNT_ID || '').trim();
  const bucket = (env.R2_BUCKET || '').trim();
  const chaveId = (env.R2_ACCESS_KEY_ID || '').trim();
  const segredo = (env.R2_SECRET_ACCESS_KEY || '').trim();

  const host = `${conta}.r2.cloudflarestorage.com`;
  const url = `https://${host}/${bucket}/${caminho}`;

  const agora = new Date();
  const dataHora = agora.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const dia = dataHora.slice(0, 8);
  const escopo = `${dia}/auto/s3/aws4_request`;

  const hashCorpo = await sha256Hex(corpo);

  // os cabeçalhos assinados vão em ordem alfabética, em minúsculas
  const cabecalhos: Record<string, string> = {
    'content-type': tipo,
    host,
    'x-amz-content-sha256': hashCorpo,
    'x-amz-date': dataHora,
  };

  const nomes = Object.keys(cabecalhos).sort();
  const canonicos = nomes.map((n) => `${n}:${cabecalhos[n]}\n`).join('');
  const assinados = nomes.join(';');

  // cada segmento do caminho é codificado, mas as barras permanecem
  const caminhoCanonico = `/${bucket}/${caminho}`
    .split('/')
    .map((p) => encodeURIComponent(p))
    .join('/');

  const requisicaoCanonica = [
    'PUT', caminhoCanonico, '', canonicos, assinados, hashCorpo,
  ].join('\n');

  const paraAssinar = [
    'AWS4-HMAC-SHA256',
    dataHora,
    escopo,
    await sha256Hex(requisicaoCanonica),
  ].join('\n');

  // a chave é derivada em quatro etapas encadeadas
  const kData = await hmac(new TextEncoder().encode(`AWS4${segredo}`), dia);
  const kRegiao = await hmac(kData, 'auto');
  const kServico = await hmac(kRegiao, 's3');
  const kAssinatura = await hmac(kServico, 'aws4_request');
  const assinatura = paraHex(await hmac(kAssinatura, paraAssinar));

  const auth = `AWS4-HMAC-SHA256 Credential=${chaveId}/${escopo}, `
             + `SignedHeaders=${assinados}, Signature=${assinatura}`;

  try {
    const r = await fetch(url, {
      method: 'PUT',
      headers: {
        Authorization: auth,
        'Content-Type': tipo,
        'x-amz-content-sha256': hashCorpo,
        'x-amz-date': dataHora,
        'Cache-Control': 'public, max-age=31536000, immutable',
      },
      body: corpo,
    });

    if (r.ok) return { ok: true, status: r.status };

    const texto = await r.text().catch(() => '');
    // o R2 devolve XML; a mensagem interessa mais que a tag
    const msg = (texto.match(/<Message>([^<]+)<\/Message>/) || [])[1] || texto.slice(0, 200);
    return { ok: false, status: r.status, erro: msg || `http ${r.status}` };

  } catch (e: any) {
    return { ok: false, erro: String(e?.message || e) };
  }
}

async function subirImagem(req: Request, env: Env, ch: Record<string, string>) {
  const faltando = [
    !env.R2_ACCOUNT_ID && 'R2_ACCOUNT_ID',
    !env.R2_BUCKET && 'R2_BUCKET',
    !env.R2_ACCESS_KEY_ID && 'R2_ACCESS_KEY_ID',
    !env.R2_SECRET_ACCESS_KEY && 'R2_SECRET_ACCESS_KEY',
    !env.R2_PUBLICO && 'R2_PUBLICO',
  ].filter(Boolean);

  if (faltando.length) {
    return jsonResponse({
      ok: false,
      erro: `faltam variaveis no Worker: ${faltando.join(', ')}. `
          + 'Veja R2-IMAGENS.md para onde pegar cada uma.',
    }, 400, ch);
  }

  const form = await req.formData().catch(() => null);
  const arquivo = form?.get('arquivo');

  if (!arquivo || typeof arquivo === 'string') {
    return jsonResponse({ ok: false, erro: 'nenhum arquivo recebido' }, 400, ch);
  }

  const tipo = (arquivo as File).type || '';
  const ext = TIPOS_IMAGEM[tipo];
  if (!ext) {
    return jsonResponse({
      ok: false,
      erro: `tipo ${tipo || 'desconhecido'} nao aceito. Use JPG, PNG, GIF ou WEBP.`,
    }, 400, ch);
  }

  const bytes = await (arquivo as File).arrayBuffer();

  if (bytes.byteLength > LIMITE_IMAGEM) {
    return jsonResponse({
      ok: false,
      erro: `a imagem tem ${(bytes.byteLength / 1048576).toFixed(1)} MB e o limite e 5 MB. `
          + 'Imagem pesada demora a carregar e alguns clientes cortam o e-mail.',
    }, 400, ch);
  }

  // nome com data e sorteio: nome repetido sobrescreveria uma imagem
  // que já está num e-mail enviado
  const hoje = new Date().toISOString().slice(0, 10);
  const aleatorio = crypto.randomUUID().slice(0, 8);
  const limpo = String((arquivo as File).name || 'imagem')
    .toLowerCase()
    .replace(/\.[^.]+$/, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40) || 'imagem';

  const caminho = `email/${hoje}/${limpo}-${aleatorio}.${ext}`;

  const r = await enviarParaR2(env, caminho, bytes, tipo);

  if (!r.ok) {
    const dica = r.status === 403
      ? ' — verifique se o token do R2 tem permissao de escrita neste bucket'
      : '';
    return jsonResponse({
      ok: false, erro: `${r.erro}${dica}`, status: r.status,
    }, 502, ch);
  }

  const base = (env.R2_PUBLICO || '').replace(/\/+$/, '');

  return jsonResponse({
    ok: true,
    url: `${base}/${caminho}`,
    caminho,
    tamanho: bytes.byteLength,
    tipo,
  }, 200, ch);
}


// =====================================================================
// REATIVAÇÃO DE LEADS
//
// Manda a base de lançamentos anteriores para uma automação do
// SellFlux. O envio vai em lotes porque a base pode ter milhares de
// pessoas e o Worker tem limite de tempo por requisição — a tela chama
// esta rota repetidamente até a fila acabar.
//
// Cada lote registra quem foi antes de seguir, então parar no meio e
// retomar não manda duas vezes para ninguém.
// =====================================================================

// =====================================================================
// PARA ONDE CADA LEAD VAI
//
// A dash manda lead para o SellFlux em quatro situações, e elas usam
// destinos diferentes. Escolher o errado põe a pessoa na sequência
// errada — foi o que aconteceu quando a fila de reativação apontou
// para o webhook de captação e 500 leads antigos entraram no fluxo de
// quem acabou de se inscrever.
//
// Por isso a escolha acontece num lugar só. Quem envia pede o destino
// pelo nome do que está fazendo, não monta a URL por conta própria.
// =====================================================================
type DestinoLead = 'captacao' | 'reativacao';

async function destinoSellflux(
  qual: DestinoLead, db: Supabase, env: Env,
): Promise<{ url: string | null; nome: string; fonte: string }> {

  if (qual === 'reativacao') {
    // O fluxo de volta, para lead de lançamento antigo.
    const url = String(env.SELLFLUX_REATIVACAO || '').trim()
      || SELLFLUX_REATIVACAO_PADRAO;

    return {
      url: url ? (/^https?:\/\//i.test(url) ? url : `https://${url}`) : null,
      nome: 'reativação',
      fonte: env.SELLFLUX_REATIVACAO ? 'SELLFLUX_REATIVACAO' : 'padrão do código',
    };
  }

  // A sequência de aquecimento do lançamento em andamento.
  const cfg = await segredoIntegracao('sellflux', 'endpoint', db);
  const url = (cfg?.ativa && cfg?.valor) || env.SELLFLUX_ENDPOINT || '';

  return {
    url: url ? (/^https?:\/\//i.test(url) ? url : `https://${url}`) : null,
    nome: 'captação',
    fonte: (cfg?.ativa && cfg?.valor) ? 'tela de Integrações' : 'SELLFLUX_ENDPOINT',
  };
}

/** Automação de reativação no SellFlux. Trocável por SELLFLUX_REATIVACAO. */
const SELLFLUX_REATIVACAO_PADRAO =
  'https://webhook.sellflux.app/v2/webhook/form_game/d576e8b8ae89eb7625f0ba0e6414320f';

async function enviarReativacao(
  corpo: any, db: Supabase, env: Env,
): Promise<any> {
  // A automação de reativação tem URL própria, diferente da captação:
  // usar a da captação jogaria estes leads no fluxo de lead novo do
  // lançamento em andamento.
  //
  // Fica aqui porque não muda de campanha para campanha. Para trocar
  // sem mexer no código, basta criar SELLFLUX_REATIVACAO no Worker.
  // O endpoint vem da função, não do corpo da requisição: aceitar URL
  // de fora deixaria a tela mandar lead para qualquer lugar.
  const destino = await destinoSellflux('reativacao', db, env);
  const url = destino.url;

  if (!url) {
    return { ok: false, erro: 'endpoint de reativacao nao configurado' };
  }

  const campanha = String(corpo.campanha || '').trim();
  if (!campanha) return { ok: false, erro: 'de um nome a campanha' };

  const plano = await db.rpc('lote_reativacao', {
    p: {
      campanha,
      lancamentos: corpo.lancamentos || [],
      pergunta: corpo.pergunta || '',
      respostas: corpo.respostas || [],
      excluir_produtos: corpo.excluir_produtos || [],
      excluir_lancamento_atual: corpo.excluir_lancamento_atual !== false,
      limite: Number(corpo.limite || 200),
    },
  });

  const leads: any[] = plano?.leads || [];
  if (!leads.length) {
    return { ok: true, enviados: 0, falhas: 0, acabou: true };
  }

  const envios: any[] = [];
  let enviados = 0;
  let falhas = 0;
  let primeiroErro: string | null = null;

  for (const l of leads) {
    try {
      // O webhook do SellFlux espera JSON, no mesmo formato que o
      // script de captura dele envia: telefone completo com DDI em
      // "phone", e os campos extras soltos no corpo.
      const digitos = String(l.telefone || '').replace(/\D/g, '');
      const comDdi = digitos
        ? (digitos.startsWith('55') ? `+${digitos}` : `+55${digitos}`)
        : '';

      const dados: Record<string, any> = {
        name: l.nome || '',
        email: l.email || '',
        phone: comDdi,
        phoneWithDdi: comDdi,
        countryCode: '55',
        // a tag separa esta campanha das outras: a automação do
        // SellFlux dispara por ela
        tag: campanha,
        origem_lancamento: l.lancamento || '',
        engenheiro: l.engenheiro ? 'sim' : 'nao',
        // a resposta do quiz vai junto: permite ramificar a automação
        // sem precisar de uma campanha por perfil
        perfil: l.resposta || '',
        source: 'dash_reativacao',
        timestamp: new Date().toISOString(),
      };

      let r = await enviarComRepeticao(url, dados);

      const deuCerto = r.ok;
      if (deuCerto) enviados++; else falhas++;

      // A resposta do SellFlux vai junto quando falha. Guardar só o
      // código HTTP não diz nada: 604 falhas com "http 429" e 604 com
      // "http 422" pedem soluções opostas.
      let detalhe: string | null = null;
      if (!deuCerto) {
        detalhe = await r.text().catch(() => '');
        detalhe = `http ${r.status}: ${String(detalhe).slice(0, 300)}`;
        if (!primeiroErro) primeiroErro = detalhe;
      }

      envios.push({
        pessoa_id: l.pessoa_id, inscricao_id: l.inscricao_id, canal: 'email',
        resultado: deuCerto ? 'enviado' : 'falhou',
        erro: detalhe,
      });

    } catch (e: any) {
      falhas++;
      envios.push({
        pessoa_id: l.pessoa_id, inscricao_id: l.inscricao_id, canal: 'email',
        resultado: 'falhou', erro: String(e?.message || e).slice(0, 200),
      });
    }

    // Grava de 20 em 20, enquanto o laço roda.
    //
    // Se o Worker for cortado por tempo no meio, o que já foi enviado
    // está registrado — e não volta no próximo lote. Guardar tudo para
    // o fim significava perder o registro inteiro quando o tempo
    // acabava.
    if (envios.length >= 20) {
      await db.rpc('registrar_reativacao', {
        p: { campanha, envios: envios.splice(0, envios.length) },
      }).catch(() => {});
    }

    // Um limite de segurança: acima disso o Worker corre risco de ser
    // cortado. A tela chama de novo e o envio continua de onde parou.
    if (enviados + falhas >= 60) break;
  }

  // Registra o que sobrou do último bloco.
  //
  // O registro acontece em blocos durante o laço, não só aqui: o
  // Worker tem tempo limitado, e um lote grande o mata antes desta
  // linha. Foi o que aconteceu num envio de 6.147 — 54 leads chegaram
  // ao SellFlux, o Worker morreu, e nada foi gravado. No lote
  // seguinte os mesmos leads voltaram.
  let erroRegistro: string | null = null;
  if (envios.length) {
    try {
      const reg = await db.rpc('registrar_reativacao', { p: { campanha, envios } });
      if (reg?.ok === false) erroRegistro = String(reg?.erro || 'falhou sem mensagem');
    } catch (e: any) {
      erroRegistro = String(e?.message || e).slice(0, 300);
    }
  }

  if (erroRegistro) {
    // parar é mais seguro que seguir: continuar sem registro reenviaria
    // os mesmos leads
    return {
      ok: false,
      erro: `os envios nao foram gravados (${erroRegistro}). `
          + 'O envio parou aqui para nao repetir os mesmos leads.',
      enviados, falhas, lote: leads.length, acabou: true,
    };
  }

  return {
    ok: true,
    enviados,
    falhas,
    lote: leads.length,
    // a primeira mensagem de erro real, para a tela mostrar
    // menos que o limite significa que a fila acabou
    acabou: leads.length < Number(corpo.limite || 200)
            && (enviados + falhas) < 60,
    primeiro_erro: primeiroErro,
  };
}


// =====================================================================
// CONVERSIONS API DO META
//
// Manda o evento quando o lead se qualifica no quiz, não quando só
// preenche o formulário. O algoritmo passa a procurar quem se parece
// com quem se qualificou — que é o público que interessa.
//
// Três exigências do Meta que não são óbvias:
//
//   os dados pessoais vão em SHA-256, nunca em texto
//   e-mail e telefone precisam ser normalizados ANTES do hash, senão
//   o mesmo lead gera hashes diferentes e a correspondência falha
//   o event_id é o que evita contar duas vezes quando o pixel do
//   navegador também dispara
// =====================================================================

/** SHA-256 em hexadecimal, como o Meta exige. */
async function hashMeta(valor: string): Promise<string> {
  const bytes = new TextEncoder().encode(valor);
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/**
 * Normaliza antes do hash. O Meta compara hashes, então qualquer
 * diferença de espaço ou maiúscula faz o mesmo lead virar outra pessoa
 * e a correspondência simplesmente não acontece — sem erro nenhum.
 */
async function dadosMeta(campo: string, valor: string | null | undefined) {
  const v = String(valor || '').trim();
  if (!v) return undefined;

  let limpo = v.toLowerCase();

  if (campo === 'ph') {
    // só dígitos, com DDI e sem o +
    limpo = v.replace(/\D/g, '');
    if (!limpo) return undefined;
    if (!limpo.startsWith('55')) limpo = `55${limpo}`;
  }

  if (campo === 'fn' || campo === 'ln') {
    limpo = limpo.replace(/[^a-zà-ú]/g, '');
    if (!limpo) return undefined;
  }

  return hashMeta(limpo);
}

async function enviarEventosMeta(
  inscricaoId: string, db: Supabase, env: Env, extras: any = {},
): Promise<any> {
  // A configuração vive na tela de Integrações, não em variável do
  // Worker: quem troca o pixel é o cliente, e ele não tem acesso ao
  // Cloudflare. As variáveis ficam de reserva.
  const cfg = await db.rpc('config_meta_capi', { p: {} }).catch(() => null);

  if (cfg && cfg.ativa === false && !env.META_PIXEL_ID) {
    return { ok: true, enviados: 0, aviso: 'integracao do Meta desativada' };
  }

  const pixel = String(cfg?.pixel_id || env.META_PIXEL_ID || '').trim();
  const token = String(
    cfg?.token || env.META_CAPI_TOKEN || env.META_TOKEN || '',
  ).trim();
  const testEvent = String(cfg?.test_event || env.META_TEST_EVENT || '').trim();

  if (!pixel || !token) {
    return {
      ok: false,
      erro: 'configure o pixel e o token em Integracoes > Meta',
    };
  }

  const plano = await db.rpc('eventos_meta_do_lead', {
    p: { inscricao_id: inscricaoId },
  });

  const eventos: any[] = plano?.eventos || [];
  if (!eventos.length) return { ok: true, enviados: 0 };

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  let enviados = 0;
  let falhas = 0;
  let primeiroErro: string | undefined;

  for (const ev of eventos) {
    try {
      const user: Record<string, any> = {};

      const em = await dadosMeta('em', ev.email);
      if (em) user.em = [em];

      const ph = await dadosMeta('ph', ev.telefone);
      if (ph) user.ph = [ph];

      if (ev.nome) {
        const partes = String(ev.nome).trim().split(/\s+/);
        const fn = await dadosMeta('fn', partes[0]);
        if (fn) user.fn = [fn];
        if (partes.length > 1) {
          const ln = await dadosMeta('ln', partes[partes.length - 1]);
          if (ln) user.ln = [ln];
        }
      }

      // fbc e fbp melhoram muito a correspondência: eles ligam o evento
      // ao clique no anúncio, sem depender de e-mail
      if (ev.fbclid) {
        // o formato exigido é fb.1.<timestamp>.<fbclid>
        user.fbc = String(ev.fbclid).startsWith('fb.')
          ? ev.fbclid
          : `fb.1.${(ev.quando || Math.floor(Date.now() / 1000)) * 1000}.${ev.fbclid}`;
      }
      if (ev.fbp) user.fbp = ev.fbp;
      if (ev.ip) user.client_ip_address = ev.ip;
      if (ev.user_agent) user.client_user_agent = ev.user_agent;

      // sem nada que identifique a pessoa, o Meta recusa o evento
      if (!Object.keys(user).length) {
        falhas++;
        primeiroErro ||= 'lead sem e-mail, telefone ou fbclid';
        continue;
      }

      const corpo = {
        data: [{
          event_name: ev.evento,
          event_time: ev.quando || Math.floor(Date.now() / 1000),
          event_id: ev.event_id,
          action_source: 'website',
          event_source_url: ev.landing_url || undefined,
          user_data: user,
          // qualifying_group é o parâmetro que acompanha o
          // QualifiedLead: diz em que etapa a qualificação aconteceu
          custom_data: (ev.valor || ev.grupo)
            ? {
                ...(ev.valor
                  ? { value: Number(ev.valor), currency: 'BRL' }
                  : {}),
                ...(ev.grupo ? { qualifying_group: ev.grupo } : {}),
              }
            : undefined,
        }],
        ...(testEvent ? { test_event_code: testEvent } : {}),
      };

      const r = await fetch(
        `https://graph.facebook.com/${versao}/${pixel}/events?access_token=${token}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(corpo),
        },
      );

      const resposta: any = await r.json().catch(() => ({}));
      const deuCerto = r.ok && !resposta?.error;

      if (deuCerto) enviados++; else falhas++;
      if (!deuCerto) {
        primeiroErro ||= resposta?.error?.message || `http ${r.status}`;
      }

      await db.rpc('registrar_evento_meta', {
        p: {
          inscricao_id: inscricaoId,
          evento: ev.evento,
          event_id: ev.event_id,
          resultado: deuCerto ? 'enviado' : 'falhou',
          erro: deuCerto ? null : String(primeiroErro).slice(0, 300),
        },
      }).catch(() => {});

    } catch (e: any) {
      falhas++;
      primeiroErro ||= String(e?.message || e);
    }
  }

  return { ok: true, enviados, falhas, erro: primeiroErro };
}


/**
 * O slug do lançamento ativo, perguntado ao banco.
 *
 * Antes isso vinha de LANCAMENTO_PADRAO, uma variável do Worker que
 * precisava ser trocada a cada lançamento. Esquecer dela fazia o lead
 * terminar o quiz e cair num "grupo não cadastrado" — e a rotina mensal
 * já tem passos demais para incluir mais um.
 *
 * O resultado fica em memória por alguns minutos: a rota é chamada a
 * cada lead e o lançamento ativo não muda de um minuto para o outro.
 */
/**
 * O lançamento de uma inscrição.
 *
 * Sempre que existe inscrição, ela é quem manda: o lead pertence ao
 * lançamento em que se inscreveu, e não ao que está ativo agora. Com
 * dois lançamentos ativos ao mesmo tempo — o que acontece na virada —
 * usar "o ativo" entrega o quiz e o grupo errados.
 */
async function slugDaInscricao(
  inscricaoId: string | null | undefined, db: Supabase,
): Promise<string> {
  if (!inscricaoId || inscricaoId === 'undefined') return '';

  try {
    const dono = await db.select('inscricoes', {
      select: 'lancamento_id', id: `eq.${inscricaoId}`, limit: '1',
    });
    const lancId = dono?.[0]?.lancamento_id;
    if (!lancId) return '';

    const l = await db.select('lancamentos', {
      select: 'slug', id: `eq.${lancId}`, limit: '1',
    });
    return l?.[0]?.slug || '';
  } catch {
    return '';
  }
}

let cacheAtivo: { slug: string; ate: number } | null = null;

async function slugAtivo(db: Supabase, env: Env): Promise<string> {
  if (cacheAtivo && cacheAtivo.ate > Date.now()) return cacheAtivo.slug;

  try {
    const r = await db.rpc('lancamento_ativo', { p: {} });
    if (r?.slug) {
      cacheAtivo = { slug: r.slug, ate: Date.now() + 120000 };
      return r.slug;
    }
  } catch { /* cai para a variável abaixo */ }

  return env.LANCAMENTO_PADRAO || '';
}


// =====================================================================
// NOTIFICAÇÃO DE PUSH (Web Push, RFC 8291)
//
// O navegador só aceita notificação que venha assinada com a chave
// VAPID do remetente e com o corpo criptografado para aquele aparelho
// específico. Não há biblioteca disponível no Worker, então tudo é
// feito aqui — e cada etapa foi conferida contra os vetores oficiais
// do RFC.
//
// A ordem e o formato de cada passo importam: um byte fora de lugar
// produz uma mensagem que o navegador descarta em silêncio, sem erro.
// =====================================================================

function b64urlParaBytes(s: string): Uint8Array {
  const base = s.replace(/-/g, '+').replace(/_/g, '/');
  const completo = base + '='.repeat((4 - (base.length % 4)) % 4);
  const bin = atob(completo);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function bytesParaB64url(b: ArrayBuffer | Uint8Array): string {
  const bytes = b instanceof Uint8Array ? b : new Uint8Array(b);
  let bin = '';
  for (const x of bytes) bin += String.fromCharCode(x);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function hkdfPush(
  salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, tamanho: number,
): Promise<Uint8Array> {
  const chave = await crypto.subtle.importKey('raw', ikm as any, 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: salt as any, info: info as any },
    chave, tamanho * 8,
  );
  return new Uint8Array(bits);
}

/** O cabeçalho de autorização que prova quem está enviando. */
async function cabecalhoVapid(
  endpoint: string, publica: string, privada: string, contato: string,
): Promise<string> {
  const origem = new URL(endpoint).origin;

  const cabecalho = bytesParaB64url(
    new TextEncoder().encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })),
  );
  const corpo = bytesParaB64url(
    new TextEncoder().encode(JSON.stringify({
      aud: origem,
      // 12 horas: o padrão aceita até 24, e prazo curto limita o
      // estrago se o token vazar
      exp: Math.floor(Date.now() / 1000) + 12 * 3600,
      sub: contato,
    })),
  );

  const pub = b64urlParaBytes(publica);
  const chave = await crypto.subtle.importKey(
    'jwk',
    {
      kty: 'EC', crv: 'P-256',
      x: bytesParaB64url(pub.slice(1, 33)),
      y: bytesParaB64url(pub.slice(33, 65)),
      d: privada,
    },
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
  );

  const assinatura = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    chave,
    new TextEncoder().encode(`${cabecalho}.${corpo}`),
  );

  return `vapid t=${cabecalho}.${corpo}.${bytesParaB64url(assinatura)}, k=${publica}`;
}

/**
 * Criptografa o corpo para um aparelho.
 *
 * Cada inscrição tem a sua própria chave: a mesma mensagem para dois
 * celulares gera dois corpos diferentes.
 */
async function criptografarPush(
  texto: string, p256dh: string, authSecret: string,
): Promise<Uint8Array> {
  const enc = new TextEncoder();
  const uaPub = b64urlParaBytes(p256dh);
  const auth = b64urlParaBytes(authSecret);

  // par efêmero, novo a cada mensagem
  const par = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'],
  );
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', par.publicKey));

  const pubUA = await crypto.subtle.importKey(
    'raw', uaPub as any, { name: 'ECDH', namedCurve: 'P-256' }, false, [],
  );
  const segredo = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'ECDH', public: pubUA }, par.privateKey, 256,
  ));

  const salt = crypto.getRandomValues(new Uint8Array(16));

  // a ordem aqui é a do RFC: rótulo, zero, chave do aparelho, chave nossa
  const keyInfo = new Uint8Array([
    ...enc.encode('WebPush: info'), 0, ...uaPub, ...asPub,
  ]);

  const ikm = await hkdfPush(auth, segredo, keyInfo, 32);
  const cek = await hkdfPush(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdfPush(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);

  // o corpo termina com 0x02, que marca o último registro
  const dados = enc.encode(texto);
  const comPadding = new Uint8Array(dados.length + 1);
  comPadding.set(dados);
  comPadding[dados.length] = 2;

  const chaveAes = await crypto.subtle.importKey(
    'raw', cek as any, { name: 'AES-GCM' }, false, ['encrypt'],
  );
  const cifrado = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as any }, chaveAes, comPadding as any,
  ));

  // cabeçalho: salt(16) + tamanho do registro(4) + tamanho da chave(1) + chave(65)
  const corpo = new Uint8Array(16 + 4 + 1 + 65 + cifrado.length);
  corpo.set(salt, 0);
  new DataView(corpo.buffer).setUint32(16, 4096, false);
  corpo[20] = 65;
  corpo.set(asPub, 21);
  corpo.set(cifrado, 86);

  return corpo;
}

/** Manda a notificação para um aparelho. */
async function enviarPush(
  inscricao: any, titulo: string, texto: string, env: Env, extras: any = {},
): Promise<{ ok: boolean; status?: number; erro?: string; expirou?: boolean }> {
  const publica = (env.VAPID_PUBLIC_KEY || '').trim();
  const privada = (env.VAPID_PRIVATE_KEY || '').trim();

  if (!publica || !privada) {
    return { ok: false, erro: 'chaves VAPID nao configuradas no Worker' };
  }

  try {
    const carga = JSON.stringify({
      titulo, corpo: texto, tag: extras.tag || 'captacao', url: extras.url || '/',
    });

    const corpo = await criptografarPush(carga, inscricao.p256dh, inscricao.auth);

    const auth = await cabecalhoVapid(
      inscricao.endpoint, publica, privada,
      env.VAPID_CONTATO || 'mailto:contato@luishalendar.com.br',
    );

    const r = await fetch(inscricao.endpoint, {
      method: 'POST',
      headers: {
        Authorization: auth,
        'Content-Encoding': 'aes128gcm',
        'Content-Type': 'application/octet-stream',
        TTL: '86400',
        Urgency: extras.urgencia || 'normal',
      },
      body: corpo as any,
    });

    // 404 e 410 significam que o aparelho não existe mais: a inscrição
    // precisa sair da lista, senão o erro se repete para sempre
    if (r.status === 404 || r.status === 410) {
      return { ok: false, status: r.status, expirou: true, erro: 'inscricao expirada' };
    }

    if (!r.ok) {
      const t = await r.text().catch(() => '');
      return { ok: false, status: r.status, erro: t.slice(0, 200) || `http ${r.status}` };
    }

    return { ok: true, status: r.status };

  } catch (e: any) {
    return { ok: false, erro: String(e?.message || e) };
  }
}


/**
 * Manda o aviso de captação para todos os aparelhos inscritos.
 *
 * Chamada pelo cron e pelo botão de teste. Cada aparelho tem a sua
 * chave, então o corpo é criptografado uma vez por destino.
 */
async function avisarCaptacao(
  db: Supabase, env: Env, forcar = false,
): Promise<any> {
  if (!forcar) {
    const hora = await db.rpc('push_na_hora', { p: {} }).catch(() => null);
    if (!hora?.enviar) {
      return { ok: true, enviados: 0, motivo: hora?.motivo || 'nao e hora' };
    }
  }

  const texto = await db.rpc('push_texto', { p: {} }).catch(() => null);
  if (!texto?.ok) {
    return { ok: false, erro: texto?.erro || 'nao consegui montar o aviso' };
  }

  const destinos = await db.rpc('push_destinos', { p: {} }).catch(() => null);
  const lista: any[] = destinos?.destinos || [];

  if (!lista.length) {
    return { ok: true, enviados: 0, motivo: 'nenhum aparelho inscrito' };
  }

  const envios: any[] = [];
  let ok = 0;
  let falhas = 0;

  for (const d of lista) {
    const r = await enviarPush(d, texto.titulo, texto.corpo, env, {
      tag: 'captacao', url: '/',
    });
    if (r.ok) ok++; else falhas++;
    envios.push({
      inscricao_id: d.id, ok: r.ok, erro: r.erro, expirou: r.expirou,
    });
  }

  await db.rpc('registrar_push', {
    p: { titulo: texto.titulo, corpo: texto.corpo, envios, marcar_hora: !forcar },
  }).catch(() => {});

  return {
    ok: true, enviados: ok, falhas,
    titulo: texto.titulo, corpo: texto.corpo,
    primeiro_erro: envios.find((e) => e.erro)?.erro,
  };
}


// =====================================================================
// LIGAR E PAUSAR CONJUNTO PELO PAINEL
//
// Pausar o conjunto errado custa dinheiro de verdade, e no meio de uma
// captação a decisão é rápida — abrir o Gerenciador, achar a campanha,
// achar o conjunto, tudo isso enquanto o CPL sobe.
//
// Por isso a ação existe aqui, mas com três travas: só conjunto (nunca
// campanha inteira), confirmação na tela antes de enviar, e registro
// de tudo que foi feito.
// =====================================================================
async function mudarStatusAds(
  corpo: any, db: Supabase, env: Env,
): Promise<any> {
  const id = String(corpo?.id || '').trim();
  const novo = String(corpo?.status || '').toUpperCase();

  if (!id) return { ok: false, erro: 'sem o conjunto' };

  if (novo !== 'ACTIVE' && novo !== 'PAUSED') {
    return { ok: false, erro: 'status tem que ser ACTIVE ou PAUSED' };
  }

  const token = (env.META_TOKEN || '').trim();
  if (!token) return { ok: false, erro: 'META_TOKEN nao configurado' };

  // Só conjunto. Campanha e anúncio ficam de fora de propósito:
  // pausar uma campanha por engano derruba o lançamento inteiro.
  const ent = await db.select('ads_entidades', {
    select: 'id,nivel,nome,status', id: `eq.${id}`, limit: '1',
  }).catch(() => null);

  const alvo = ent?.[0];
  if (!alvo) return { ok: false, erro: 'conjunto nao encontrado na dash' };

  if (alvo.nivel !== 'adset') {
    return {
      ok: false,
      erro: `so da para ligar e pausar conjunto; este e ${alvo.nivel}`,
    };
  }

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;

  try {
    const r = await fetch(`https://graph.facebook.com/${versao}/${id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: novo, access_token: token }),
    });

    const resposta: any = await r.json().catch(() => ({}));

    if (!r.ok || resposta?.error) {
      const msg = resposta?.error?.message || `http ${r.status}`;

      // O token de leitura é o caso mais comum e a mensagem do Meta não
      // é óbvia — dizer o que fazer poupa meia hora de procura.
      const semPermissao = /permission|ads_management|OAuth/i.test(msg);

      return {
        ok: false,
        erro: semPermissao
          ? 'o token do Meta nao tem permissao de escrita. Gere um novo em '
            + 'Business Manager > Usuarios do sistema, com ads_management, '
            + 'e troque o META_TOKEN no Worker.'
          : msg,
        detalhe: msg,
      };
    }

    // o banco acompanha, para a bolinha mudar sem esperar a sincronização
    await db.update('ads_entidades', { id: `eq.${id}` }, { status: novo })
      .catch(() => {});

    await db.insert('eventos', {
      tipo: novo === 'ACTIVE' ? 'adset_ativado' : 'adset_pausado',
      ocorreu_em: new Date().toISOString(),
      fonte: 'dash',
      payload: { adset_id: id, nome: alvo.nome, de: alvo.status, para: novo },
      dedupe_key: `adset:${id}:${novo}:${Date.now()}`,
    }).catch(() => {});

    return { ok: true, id, nome: alvo.nome, status: novo };

  } catch (e: any) {
    return { ok: false, erro: String(e?.message || e) };
  }
}


// =====================================================================
// ORÇAMENTO E DUPLICAÇÃO DE CONJUNTO
//
// As duas decisões que hoje obrigam a sair da dash no meio da
// captação: um conjunto está indo bem e merece mais verba, ou merece
// ser duplicado para testar outro público.
//
// Mexer em verba tem consequência imediata, então tudo aqui passa por
// confirmação na tela e fica registrado.
// =====================================================================

/** Lê o orçamento e o gasto de hoje de um conjunto. */
async function lerConjuntoMeta(id: string, env: Env): Promise<any> {
  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  const campos = [
    'id', 'name', 'status', 'daily_budget', 'lifetime_budget',
    'bid_strategy', 'campaign_id', 'targeting',
  ].join(',');

  const r = await fetch(
    `https://graph.facebook.com/${versao}/${id}?fields=${campos}`
    + `&access_token=${encodeURIComponent(env.META_TOKEN || '')}`,
  );

  const d: any = await r.json().catch(() => ({}));
  if (!r.ok || d?.error) {
    return { ok: false, erro: d?.error?.message || `http ${r.status}` };
  }

  // o Meta trabalha em centavos; a tela mostra em reais
  return {
    ok: true,
    id: d.id,
    nome: d.name,
    status: d.status,
    diario: d.daily_budget ? Number(d.daily_budget) / 100 : null,
    total: d.lifetime_budget ? Number(d.lifetime_budget) / 100 : null,
    campanha_id: d.campaign_id,
    // orçamento na campanha (CBO): o conjunto não tem o próprio
    no_conjunto: !!(d.daily_budget || d.lifetime_budget),
  };
}

async function mudarOrcamento(
  corpo: any, db: Supabase, env: Env,
): Promise<any> {
  const id = String(corpo?.id || '').trim();
  const valor = Number(corpo?.valor);

  if (!id) return { ok: false, erro: 'sem o conjunto' };

  if (!Number.isFinite(valor) || valor <= 0) {
    return { ok: false, erro: 'valor invalido' };
  }

  // O Meta exige um mínimo por conjunto, que varia por moeda e tipo de
  // otimização. Abaixo disso ele recusa com mensagem pouco clara.
  if (valor < 6) {
    return { ok: false, erro: 'o Meta nao aceita diario abaixo de R$ 6' };
  }

  const atual = await lerConjuntoMeta(id, env);
  if (!atual.ok) return atual;

  if (!atual.no_conjunto) {
    return {
      ok: false,
      erro: 'o orcamento desta campanha esta no nivel da campanha (CBO), '
          + 'nao no conjunto. Mude no Gerenciador ou troque a campanha para ABO.',
    };
  }

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;
  const campo = atual.total ? 'lifetime_budget' : 'daily_budget';

  try {
    const r = await fetch(`https://graph.facebook.com/${versao}/${id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        [campo]: Math.round(valor * 100),
        access_token: env.META_TOKEN,
      }),
    });

    const d: any = await r.json().catch(() => ({}));

    if (!r.ok || d?.error) {
      return { ok: false, erro: d?.error?.message || `http ${r.status}` };
    }

    await db.insert('eventos', {
      tipo: 'orcamento_alterado',
      ocorreu_em: new Date().toISOString(),
      fonte: 'dash',
      payload: {
        adset_id: id, nome: atual.nome,
        de: atual.diario || atual.total, para: valor, campo,
      },
      dedupe_key: `orc:${id}:${Date.now()}`,
    }).catch(() => {});

    return {
      ok: true, id, nome: atual.nome,
      de: atual.diario || atual.total, para: valor,
      tipo: campo === 'daily_budget' ? 'diario' : 'total',
    };

  } catch (e: any) {
    return { ok: false, erro: String(e?.message || e) };
  }
}

/**
 * Duplica o conjunto com os anúncios dentro.
 *
 * A cópia pode nascer ativa ou pausada, e quem escolhe é quem clica.
 * Duplicar um conjunto que já está validado e ter que ir ao Gerenciador
 * ativar anula o ganho de fazer isso aqui — mas duplicar algo que ainda
 * precisa de ajuste e sair gastando é pior. Por isso a pergunta.
 */
async function duplicarConjunto(
  corpo: any, db: Supabase, env: Env,
): Promise<any> {
  const id = String(corpo?.id || '').trim();
  if (!id) return { ok: false, erro: 'sem o conjunto' };

  const jaAtiva = corpo?.ativar === true;

  const atual = await lerConjuntoMeta(id, env);
  if (!atual.ok) return atual;

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;

  try {
    const r = await fetch(`https://graph.facebook.com/${versao}/${id}/copies`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        deep_copy: true,              // leva os anúncios junto
        // ACTIVE só entra quando a pessoa pediu; INHERITED_FROM_SOURCE
        // copiaria o status do original, o que é ambíguo demais
        status_option: jaAtiva ? 'ACTIVE' : 'PAUSED',
        rename_options: {
          rename_strategy: 'DEEP_RENAME',
          rename_suffix: corpo?.sufixo || ' — cópia',
        },
        access_token: env.META_TOKEN,
      }),
    });

    const d: any = await r.json().catch(() => ({}));

    if (!r.ok || d?.error) {
      return { ok: false, erro: d?.error?.message || `http ${r.status}` };
    }

    const novoId = d?.copied_adset_id || d?.id;

    await db.insert('eventos', {
      tipo: 'conjunto_duplicado',
      ocorreu_em: new Date().toISOString(),
      fonte: 'dash',
      payload: {
        origem: id, nome_origem: atual.nome, novo: novoId,
        nasceu_ativo: jaAtiva,
      },
      dedupe_key: `dup:${id}:${Date.now()}`,
    }).catch(() => {});

    return {
      ok: true,
      novo_id: novoId,
      nome_origem: atual.nome,
      ativa: jaAtiva,
      orcamento: atual.diario || atual.total,
      aviso: jaAtiva
        ? 'a cópia já está rodando e gastando'
        : 'a cópia nasceu pausada — ative quando quiser',
    };

  } catch (e: any) {
    return { ok: false, erro: String(e?.message || e) };
  }
}


/**
 * Manda ao SellFlux e tenta de novo quando o erro é temporário.
 *
 * O 502 vinha de um em cada quatro envios, e o histórico do SellFlux
 * não registrava nada — a requisição morria na borda dele, sem chegar
 * à aplicação. Dar a pessoa como perdida nesse caso é jogar lead fora
 * por um engasgo de meio segundo.
 *
 * A pausa cresce a cada tentativa: insistir no mesmo ritmo contra um
 * servidor sobrecarregado piora o problema.
 */
async function enviarComRepeticao(
  url: string, dados: Record<string, any>, tentativas = 3,
): Promise<Response> {
  let r: Response | null = null;

  for (let i = 0; i < tentativas; i++) {
    if (i > 0) {
      // 400ms, 1200ms — tempo de o servidor respirar
      await new Promise((ok) => setTimeout(ok, 400 * (i * 2)));
    }

    try {
      r = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json;charset=UTF-8' },
        body: JSON.stringify(dados),
      });
    } catch (e) {
      // conexão derrubada: conta como tentativa e segue
      if (i === tentativas - 1) throw e;
      continue;
    }

    if (r.ok) return r;

    // 400 e 415 são formato recusado, não sobrecarga: vale tentar
    // como formulário, que é o que endpoint antigo espera
    if (r.status === 400 || r.status === 415) {
      const alt = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(
          Object.fromEntries(
            Object.entries(dados).map(([k, v]) => [k, String(v)]),
          ),
        ).toString(),
      }).catch(() => null);

      if (alt?.ok) return alt;
      return alt || r;
    }

    // 4xx que não seja 408 ou 429 é recusa de verdade: repetir não muda
    if (r.status >= 400 && r.status < 500
        && r.status !== 408 && r.status !== 429) {
      return r;
    }

    // 5xx, 408 e 429 são temporários: volta para o laço
  }

  return r as Response;
}


// =====================================================================
// A FILA DE REATIVAÇÃO, PROCESSADA PELO CRON
//
// Antes o navegador comandava: cada volta era uma chamada da tela, e
// fechar a aba parava o envio. Em 853 leads isso eram 4 minutos de
// tela aberta.
//
// Agora o clique só enfileira. Isto roda em segundo plano, em
// paralelo, e o 502 do SellFlux não perde mais o lead — ele volta para
// a fila com hora marcada.
// =====================================================================
async function processarFilaReativacao(
  db: Supabase, env: Env, limite = 40,
): Promise<any> {
  const destino = await destinoSellflux('reativacao', db, env);
  const url = destino.url;

  if (!url) return { ok: false, erro: 'endpoint de reativacao nao configurado' };

  const lote = await db.rpc('fila_reativacao_proximo', { p: { limite } });
  const leads: any[] = lote?.leads || [];

  if (!leads.length) return { ok: true, vazia: true, enviados: 0 };

  // Em paralelo, de 8 em 8.
  //
  // Um a um levava 300ms cada; oito ao mesmo tempo cortam o tempo por
  // oito. Mais que isso e o SellFlux começa a devolver 502 — foi o que
  // aconteceu quando a tela mandava tudo em sequência rápida.
  const resultados: any[] = [];
  const porVez = 8;

  for (let i = 0; i < leads.length; i += porVez) {
    const bloco = leads.slice(i, i + porVez);

    await Promise.all(bloco.map(async (l: any) => {
      const dados = {
        name: l.nome || '',
        email: l.email || '',
        phone: (l.telefone || '').replace(/^\+/, ''),
        tag: l.campanha,
        origem_lancamento: l.lancamento || '',
        engenheiro: l.engenheiro ? 'sim' : 'nao',
        perfil: l.resposta || '',
        source: 'dash_reativacao',
        timestamp: new Date().toISOString(),
      };

      try {
        const r = await enviarComRepeticao(url, dados);

        if (r.ok) {
          resultados.push({ fila_id: l.fila_id, enviado: true });
          return;
        }

        const texto = await r.text().catch(() => '');
        // 5xx, 408 e 429 são engasgo passageiro: o lead volta para a
        // fila em vez de ser dado como perdido
        const temporario = r.status >= 500 || r.status === 408 || r.status === 429;

        resultados.push({
          fila_id: l.fila_id, enviado: false, temporario,
          erro: `http ${r.status}: ${String(texto).slice(0, 200)}`,
        });

      } catch (e: any) {
        // erro de rede também é passageiro
        resultados.push({
          fila_id: l.fila_id, enviado: false, temporario: true,
          erro: String(e?.message || e).slice(0, 200),
        });
      }
    }));
  }

  const r = await db.rpc('fila_reativacao_resultado', { p: { resultados } });

  return {
    ok: true,
    pegos: leads.length,
    enviados: r?.enviados || 0,
    voltaram: r?.voltaram_para_fila || 0,
    desistiu: r?.desistiu || 0,
  };
}


// =====================================================================
// EXPORTAR LEADS EM CSV
//
// O escape fica aqui, num lugar só: um nome com vírgula ("Silva, João")
// ou com aspas quebra o arquivo inteiro se for escrito cru, e o erro
// só aparece quando alguém abre a planilha e vê as colunas trocadas.
// =====================================================================
function montarCsv(linhas: any[], colunas: string[]): string {
  const campo = (v: any) => {
    const s = v == null ? '' : String(v);
    // Aspas sempre, não só quando "precisa": o Excel decide o tipo da
    // célula pelo conteúdo, e um telefone ou CEP sem aspas viraria
    // número, perdendo o zero da frente.
    return '"' + s.replace(/"/g, '""') + '"';
  };

  const cabecalho = colunas.map(campo).join(',');
  const corpo = linhas
    .map((l) => colunas.map((c) => campo(l[c])).join(','))
    .join('\r\n');

  // O BOM faz o Excel ler como UTF-8. Sem ele, "Município" vira
  // "MunicÃ­pio" — e o cliente acha que a dash corrompeu os dados.
  // O \r\n é o que o Excel espera como fim de linha.
  return '\ufeff' + cabecalho + '\r\n' + corpo + '\r\n';
}


// =====================================================================
// INSTAGRAM — OS NÚMEROS DO CONTEÚDO
//
// O que a API oficial dá e raspagem não pega: salvamentos,
// compartilhamentos e alcance. Salvamento é o melhor sinal de conteúdo
// que funciona — quem salva pretende voltar.
//
// Cada post exige uma chamada de insights à parte da listagem, então a
// sincronização guarda no banco e a tela lê de lá.
// =====================================================================

/** As contas de Instagram que este token alcança, para o cliente escolher. */
async function igContasDisponiveis(env: Env): Promise<any> {
  const token = (env.META_TOKEN || '').trim();
  if (!token) return { ok: false, erro: 'META_TOKEN nao configurado' };

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;

  // A conta do Instagram é alcançada pela Página do Facebook ligada a
  // ela — não existe caminho direto pelo usuário.
  const r = await fetch(
    `https://graph.facebook.com/${versao}/me/accounts`
    + `?fields=id,name,instagram_business_account{id,username,name,followers_count}`
    + `&limit=100&access_token=${encodeURIComponent(token)}`,
  );

  const d: any = await r.json().catch(() => ({}));

  if (!r.ok || d?.error) {
    const msg = d?.error?.message || `http ${r.status}`;
    const semPagina = /pages_|permission/i.test(msg);

    return {
      ok: false,
      erro: semPagina
        ? 'o token nao alcanca nenhuma Pagina. No Business Manager, atribua a '
          + 'Pagina do Facebook e a conta do Instagram ao usuario do sistema, '
          + 'e gere o token de novo incluindo instagram_basic, '
          + 'instagram_manage_insights e pages_read_engagement.'
        : msg,
      detalhe: msg,
    };
  }

  const contas = (d?.data || [])
    .filter((p: any) => p?.instagram_business_account?.id)
    .map((p: any) => ({
      id: p.instagram_business_account.id,
      username: p.instagram_business_account.username,
      nome: p.instagram_business_account.name || p.name,
      seguidores: p.instagram_business_account.followers_count ?? null,
      pagina_id: p.id,
      pagina_nome: p.name,
    }));

  return {
    ok: true,
    contas,
    aviso: contas.length ? undefined
      : 'as Paginas foram encontradas, mas nenhuma tem conta do Instagram '
        + 'vinculada. A conta precisa ser Comercial ou de Criador de conteudo, '
        + 'ligada a uma Pagina.',
  };
}

/**
 * Quais métricas pedir, por tipo de post.
 *
 * Pedir uma métrica que o tipo não tem faz o Meta recusar a chamada
 * inteira — e aí o post fica sem número nenhum, não só sem aquele.
 */
function igMetricas(produto: string, tipo: string): string[] {
  if (tipo === 'CAROUSEL_ALBUM') return [];   // álbum não tem insights

  if (produto === 'STORY') {
    return ['reach', 'views', 'shares', 'total_interactions'];
  }

  // feed e reels
  return ['reach', 'views', 'saved', 'shares', 'total_interactions'];
}

async function igSincronizar(
  corpo: any, db: Supabase, env: Env,
): Promise<any> {
  const token = (env.META_TOKEN || '').trim();
  if (!token) return { ok: false, erro: 'META_TOKEN nao configurado' };

  const versao = env.META_API_VERSAO || META_VERSAO_PADRAO;

  // a conta ativa, ou a informada
  let contaId = String(corpo?.conta_id || '').trim();
  if (!contaId) {
    const c = await db.select('ig_contas', {
      select: 'id', ativa: 'is.true', limit: '1',
    }).catch(() => null);
    contaId = c?.[0]?.id || '';
  }

  if (!contaId) return { ok: false, erro: 'nenhuma conta do Instagram conectada' };

  const quantos = Math.min(Math.max(Number(corpo?.quantos || 30), 1), 100);

  // ---- a lista de posts
  const campos = [
    'id', 'caption', 'media_type', 'media_product_type', 'permalink',
    'thumbnail_url', 'media_url', 'timestamp', 'like_count', 'comments_count',
  ].join(',');

  const rl = await fetch(
    `https://graph.facebook.com/${versao}/${contaId}/media`
    + `?fields=${campos}&limit=${quantos}`
    + `&access_token=${encodeURIComponent(token)}`,
  );

  const dl: any = await rl.json().catch(() => ({}));

  if (!rl.ok || dl?.error) {
    return { ok: false, erro: dl?.error?.message || `http ${rl.status}` };
  }

  const midias: any[] = dl?.data || [];
  if (!midias.length) return { ok: true, posts: 0, aviso: 'nenhum post na conta' };

  // ---- os insights, em paralelo de 6
  //
  // Um por vez levaria 300ms cada; seis ao mesmo tempo cortam o tempo
  // por seis, e o Worker tem limite de tempo por execução.
  const posts: any[] = [];
  const porVez = 6;

  for (let i = 0; i < midias.length; i += porVez) {
    const bloco = midias.slice(i, i + porVez);

    await Promise.all(bloco.map(async (m: any) => {
      const produto = m.media_product_type || 'FEED';
      const metricas = igMetricas(produto, m.media_type || '');

      const post: any = {
        id: m.id,
        tipo: m.media_type || null,
        produto,
        legenda: m.caption || null,
        permalink: m.permalink || null,
        thumb: m.thumbnail_url || m.media_url || null,
        publicado_em: m.timestamp || null,
        curtidas: m.like_count ?? null,
        comentarios: m.comments_count ?? null,
      };

      if (!metricas.length) {
        post.insights_erro = 'album nao tem insights';
        posts.push(post);
        return;
      }

      try {
        const ri = await fetch(
          `https://graph.facebook.com/${versao}/${m.id}/insights`
          + `?metric=${metricas.join(',')}`
          + `&access_token=${encodeURIComponent(token)}`,
        );

        const di: any = await ri.json().catch(() => ({}));

        if (!ri.ok || di?.error) {
          // Post recém-publicado às vezes ainda não tem número, e
          // alguns tipos recusam métricas que a documentação diz que
          // aceitam. Guardar o motivo evita investigar de novo depois.
          post.insights_erro = String(di?.error?.message || `http ${ri.status}`)
            .slice(0, 200);
          posts.push(post);
          return;
        }

        for (const item of (di?.data || [])) {
          const valor = item?.values?.[0]?.value ?? null;
          if (item.name === 'reach') post.alcance = valor;
          if (item.name === 'views') post.views = valor;
          if (item.name === 'saved') post.salvos = valor;
          if (item.name === 'shares') post.compartilhados = valor;
          if (item.name === 'total_interactions') post.interacoes = valor;
        }

        posts.push(post);

      } catch (e: any) {
        post.insights_erro = String(e?.message || e).slice(0, 200);
        posts.push(post);
      }
    }));
  }

  const r = await db.rpc('ig_salvar_posts', {
    p: { conta_id: contaId, posts },
  });

  const semInsights = posts.filter((p) => p.insights_erro).length;

  return {
    ok: true,
    posts: posts.length,
    novos: r?.novos || 0,
    sem_insights: semInsights,
    total_na_base: r?.total_na_base || 0,
  };
}


// =====================================================================
// CONECTOR MCP — O CLAUDE DO CLIENTE CONSULTANDO A DASH
//
// O Luis pagava o Windsor.ai para levar os números do Instagram até uma
// IA. Isto substitui: o Claude dele conecta na dash e pergunta direto,
// sem exportar nem colar planilha.
//
// Só leitura. Um conector que não escreve não pode estragar nada — e a
// URL é o segredo de acesso, então essa trava importa.
//
// Autenticação: o Claude aceita conector sem OAuth, então o segredo vai
// no caminho da URL, como já acontece com os webhooks da dash. Quem tem
// a URL tem os dados, e é por isso que ela nunca aparece em log.
// =====================================================================

/** As versões do protocolo que este servidor atende. */
const MCP_VERSOES = [
  '2026-07-28', '2025-11-25', '2025-06-18', '2025-03-26',
];

/**
 * As ferramentas que o Claude vê.
 *
 * Quatro, não quarenta: cada ferramenta a mais é uma escolha a mais
 * para o modelo errar, e o caso de uso é analisar conteúdo e entender o
 * lançamento.
 */
function mcpFerramentas() {
  return [
    // ---------- conteúdo ----------
    {
      name: 'posts_instagram',
      area: 'conteúdo',
      description:
        'Os posts do Instagram com desempenho: curtidas, comentários, '
        + 'salvamentos, compartilhamentos, alcance, views e taxa de '
        + 'engajamento sobre o alcance. Use para analisar que conteúdo '
        + 'funciona e propor os próximos. O salvamento é o sinal mais '
        + 'forte: quem salva pretende voltar.',
      inputSchema: {
        type: 'object',
        properties: {
          formato: { type: 'string', enum: ['REELS', 'FEED', 'STORY'],
            description: 'Filtra por formato. Vazio traz todos.' },
          ordem: { type: 'string',
            enum: ['data', 'taxa', 'salvos', 'views', 'alcance', 'comentarios'],
            description: 'Como ordenar. O padrão é por data.' },
          dias: { type: 'integer', description: 'Só os últimos N dias.' },
        },
      },
    },
    {
      name: 'analise_formatos',
      area: 'conteúdo',
      description:
        'Compara os formatos do Instagram entre si — Reels, Feed, Stories — '
        + 'com views médio, alcance médio, salvamentos médio e engajamento. '
        + 'Traz os cinco posts que mais e os cinco que menos engajaram. '
        + 'Use para decidir em que formato investir.',
      inputSchema: {
        type: 'object',
        properties: {
          dias: { type: 'integer', description: 'Período. O padrão é 90 dias.' },
        },
      },
    },

    // ---------- tráfego pago ----------
    {
      name: 'desempenho_criativos',
      area: 'tráfego pago',
      description:
        'Os anúncios pagos por criativo: leads, engenheiros, investido, '
        + 'custo por lead, custo por engenheiro, compras e a divisão por '
        + 'resposta do quiz. Marca os criativos que gastaram sem trazer '
        + 'lead. Use para saber que ângulo funciona no tráfego e onde '
        + 'está havendo desperdício.',
      inputSchema: {
        type: 'object',
        properties: {
          lancamento: { type: 'string',
            description: 'Código do lançamento. Vazio usa o ativo.' },
          de: { type: 'string', description: 'Data inicial, AAAA-MM-DD.' },
          ate: { type: 'string', description: 'Data final, AAAA-MM-DD.' },
        },
      },
    },
    {
      name: 'conjuntos_do_criativo',
      area: 'tráfego pago',
      description:
        'Abre um criativo nos conjuntos de anúncio onde ele roda, com o '
        + 'público de cada um, leads, custo e se está ativo ou pausado. '
        + 'Use quando o criativo agregado parece bom ou ruim mas você '
        + 'precisa saber em qual público. Peça primeiro o '
        + 'desempenho_criativos para descobrir a chave do criativo.',
      inputSchema: {
        type: 'object',
        properties: {
          chave: { type: 'string',
            description: 'A chave do criativo, como aparece em desempenho_criativos.' },
          lancamento: { type: 'string', description: 'Vazio usa o ativo.' },
        },
        required: ['chave'],
      },
    },
    {
      name: 'captacao_dia_a_dia',
      area: 'tráfego pago',
      description:
        'A série diária do lançamento: leads, engenheiros, investido e '
        + 'custo por lead de cada dia. Use para ver tendência, identificar '
        + 'o dia em que o custo subiu e relacionar com o que foi publicado '
        + 'ou mudado nas campanhas.',
      inputSchema: {
        type: 'object',
        properties: {
          dias: { type: 'integer', description: 'Quantos dias. O padrão é 30.' },
          lancamento: { type: 'string', description: 'Vazio usa o ativo.' },
        },
      },
    },

    // ---------- leads ----------
    {
      name: 'funil_de_leads',
      area: 'leads',
      description:
        'O funil da captação: quantos leads entraram, quantos fizeram o '
        + 'quiz, quantos clicaram no link do grupo e quantos entraram no '
        + 'grupo do WhatsApp, com as taxas entre as etapas. Use para achar '
        + 'onde o lead está escapando.',
      inputSchema: {
        type: 'object',
        properties: {
          lancamento: { type: 'string', description: 'Vazio usa o ativo.' },
        },
      },
    },
    {
      name: 'perfil_da_base',
      area: 'leads',
      description:
        'Quem são os leads, segundo as respostas do quiz: todas as '
        + 'perguntas com a distribuição das respostas em número e '
        + 'porcentagem. Use para entender o público que está entrando e '
        + 'ajustar a comunicação. Não traz nome nem contato de ninguém.',
      inputSchema: {
        type: 'object',
        properties: {
          lancamento: { type: 'string', description: 'Vazio usa o ativo.' },
        },
      },
    },
    {
      name: 'buscar_lead',
      area: 'leads',
      description:
        'A ficha de UM lead, procurado por e-mail, telefone ou nome: em '
        + 'que lançamentos participou, o que respondeu no quiz, se entrou '
        + 'no grupo e o que comprou. Use quando a pergunta é sobre uma '
        + 'pessoa específica. Não existe jeito de listar a base inteira, '
        + 'de propósito.',
      inputSchema: {
        type: 'object',
        properties: {
          busca: { type: 'string',
            description: 'E-mail, telefone ou nome do lead.' },
        },
        required: ['busca'],
      },
    },

    // ---------- negócio ----------
    {
      name: 'recuperacao_vendas',
      area: 'leads',
      description:
        'Vendas que não fecharam e ainda dá para recuperar, separadas '
        + 'por motivo: PIX aguardando, boleto gerado, boleto vencido, '
        + 'cartão recusado, checkout abandonado, financiamento da TMB '
        + 'incompleto, cancelada. Traz quanto dinheiro está em aberto, '
        + 'o que fazer em cada caso e há quantos dias cada pessoa está '
        + 'parada. Uma linha por pessoa e por produto: quem tentou pagar '
        + 'três vezes aparece uma vez, com as outras tentativas dentro. '
        + 'Quem acabou comprando não aparece.',
      inputSchema: {
        type: 'object',
        properties: {
          lancamento: {
            type: 'string',
            description: 'slug do lançamento; vazio usa o ativo',
          },
          motivos: {
            type: 'array',
            items: { type: 'string' },
            description:
              'filtra por motivo. Valores: pix_aguardando, boleto_gerado, '
              + 'boleto_vencido, pix_expirado, cartao_recusado, '
              + 'checkout_abandonado, carrinho_abandonado, '
              + 'financiamento_incompleto, em_analise, atrasada, '
              + 'aguardando_pagamento, expirada, cancelada, reembolsada, '
              + 'chargeback. Vazio traz todos.',
          },
          plataformas: {
            type: 'array',
            items: { type: 'string' },
            description: 'hotmart, tmb, kiwify... vazio traz todas',
          },
          so_com_telefone: {
            type: 'boolean',
            description: 'só quem tem telefone, para abordagem por WhatsApp',
          },
        },
      },
    },
    {
      name: 'resumo_lancamento',
      area: 'negócio',
      description:
        'O quadro completo do lançamento: leads, engenheiros, investido, '
        + 'custo por lead e por engenheiro, vendas, receita, ROAS, ticket, '
        + 'lucro, margem, conversão e progresso das metas. É a primeira '
        + 'ferramenta a chamar quando a pergunta é "como está o lançamento".',
      inputSchema: {
        type: 'object',
        properties: {
          lancamento: { type: 'string', description: 'Vazio usa o ativo.' },
        },
      },
    },
    {
      name: 'vendas',
      area: 'negócio',
      description:
        'As vendas do lançamento: receita bruta e líquida, aprovadas, '
        + 'pendentes, reembolsos, ticket médio, quebra por produto e por '
        + 'plataforma. Use para entender o que está vendendo e o que não.',
      inputSchema: {
        type: 'object',
        properties: {
          lancamento: { type: 'string', description: 'Vazio usa o ativo.' },
        },
      },
    },
    {
      name: 'aulas',
      area: 'negócio',
      description:
        'O desempenho das aulas do evento: views, pico de audiência, '
        + 'presentes no fim, retenção média e comentários de cada uma, '
        + 'comparado com o lançamento anterior. Use para avaliar o '
        + 'aquecimento e planejar o próximo evento.',
      inputSchema: {
        type: 'object',
        properties: {
          lancamento: { type: 'string', description: 'Vazio usa o ativo.' },
        },
      },
    },

    // ---------- histórico e saúde ----------
    {
      name: 'comparar_lancamentos',
      area: 'histórico',
      description:
        'Todos os lançamentos lado a lado: leads, engenheiros, investido, '
        + 'CPL, receita, ROAS e conversão de cada um. Use para responder '
        + 'se este lançamento está melhor ou pior que os anteriores.',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'saude_da_dash',
      area: 'histórico',
      description:
        'O que está com problema: webhooks falhando, leads sem telefone '
        + 'válido, gasto sem lead correspondente. Use quando algum número '
        + 'parecer errado, ou quando pedirem um diagnóstico geral.',
      inputSchema: {
        type: 'object',
        properties: {
          dias: { type: 'integer', description: 'Período. O padrão é 7 dias.' },
        },
      },
    },
  ];
}

async function mcpChamar(
  nome: string, args: any, db: Supabase, env: Env,
): Promise<string> {

  // Os números viram texto, não JSON cru: o modelo lê melhor, e a
  // resposta não estoura com chaves e colchetes.
  const num = (v: any) => (v == null ? '-' : String(v));
  const reais = (v: any) => (v == null ? '-' : `R$ ${v}`);
  const pct = (v: any) => (v == null ? '-' : `${v}%`);
  const lanc = () => args?.lancamento || '';

  // ---------- conteúdo ----------
  if (nome === 'posts_instagram') {
    const dias = Number(args?.dias);
    const de = Number.isFinite(dias) && dias > 0
      ? new Date(Date.now() - dias * 86400000).toISOString().slice(0, 10) : '';

    const r = await db.rpc('dash_instagram', {
      p: { de, tipo: args?.formato || '', ordem: args?.ordem || 'data' },
    });

    if (r?.sem_conta) {
      return 'Nenhuma conta do Instagram conectada. '
        + 'Conecte em Ferramentas > Conteudo na dash.';
    }

    const posts: any[] = (r?.posts || []).slice(0, 40);
    const c = r?.conta || {};
    const s = r?.resumo || {};

    const linhas = posts.map((p: any) => {
      const pedacos = [
        p.produto || 'FEED',
        (p.publicado_em || '').slice(0, 10),
        `${p.curtidas ?? 0} curtidas`,
        `${p.comentarios ?? 0} comentarios`,
      ];
      if (p.salvos != null) pedacos.push(`${p.salvos} salvos`);
      if (p.compartilhados != null) pedacos.push(`${p.compartilhados} compart`);
      if (p.alcance != null) pedacos.push(`alcance ${p.alcance}`);
      if (p.views != null) pedacos.push(`${p.views} views`);
      if (p.taxa != null) pedacos.push(`engajou ${p.taxa}%`);

      const legenda = String(p.legenda || '(sem legenda)')
        .replace(/\s+/g, ' ').slice(0, 140);
      return `- "${legenda}"\n  ${pedacos.join(' | ')}`;
    });

    return [
      `Conta: @${c.username || '?'}`
        + (c.seguidores ? ` (${c.seguidores} seguidores)` : ''),
      `Periodo: ${s.posts || 0} posts, ${s.salvos || 0} salvamentos`
        + (s.taxa_media != null ? `, engajamento medio ${s.taxa_media}%` : ''),
      '',
      'A taxa de engajamento e sobre o ALCANCE, nao sobre seguidores:',
      'mede se quem viu reagiu.',
      '',
      ...linhas,
      posts.length >= 40 ? '\n(os 40 primeiros)' : '',
    ].filter(Boolean).join('\n');
  }

  if (nome === 'analise_formatos') {
    const r = await db.rpc('ig_analise', { p: { dias: args?.dias || '' } });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const tabela = (r?.por_formato || []).map((f: any) =>
      `- ${f.formato}: ${f.posts} posts | views medio ${f.views_medio} | `
      + `alcance medio ${f.alcance_medio} | salvos medio ${f.salvos_medio} | `
      + `engajamento ${f.taxa_media ?? '-'}%`);

    const lista = (arr: any[], titulo: string) => {
      if (!arr?.length) return '';
      return `\n${titulo}\n` + arr.map((p: any) =>
        `- ${p.taxa}% (${p.produto}, ${(p.publicado_em || '').slice(0, 10)}): `
        + `"${String(p.legenda || '').replace(/\s+/g, ' ').slice(0, 120)}"`
        + (p.salvos != null ? ` - ${p.salvos} salvos` : '')).join('\n');
    };

    return [
      `Ultimos ${r?.dias || 90} dias, por formato:`,
      ...tabela,
      lista(r?.melhores, 'Os que mais engajaram:'),
      lista(r?.piores, 'Os que menos engajaram:'),
    ].filter(Boolean).join('\n');
  }

  // ---------- tráfego pago ----------
  if (nome === 'desempenho_criativos') {
    const r = await db.rpc('dash_anuncios', {
      p: { lancamento: lanc(), de: args?.de || '', ate: args?.ate || '' },
    });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const anuncios: any[] = (r?.anuncios || []).slice(0, 25);
    const colunas: any[] = r?.colunas_quiz || [];
    const q = r?.queimando || {};

    const linhas = anuncios.map((a: any) => {
      const pedacos = [`${a.leads} leads`, `${a.engenheiros} engenheiros`];
      if (a.gasto) pedacos.push(`${reais(a.gasto)} investido`);
      if (a.cpl != null) pedacos.push(`CPL ${reais(a.cpl)}`);
      if (a.cpl_engenheiro != null) pedacos.push(`CPL eng ${reais(a.cpl_engenheiro)}`);
      if (a.compras) pedacos.push(`${a.compras} compras`);
      if (a.roas != null) pedacos.push(`ROAS ${a.roas}x`);
      pedacos.push(a.ativo ? 'ativo' : 'pausado');
      if (a.queimando) pedacos.push('*** GASTOU SEM TRAZER LEAD ***');

      const perfis = colunas
        .map((c: any) => {
          const n = Number((a.respostas || {})[c.valor] || 0);
          return n ? `${c.label}: ${n}` : '';
        }).filter(Boolean);

      return `- ${a.anuncio} (chave: ${a.chave})\n  ${pedacos.join(' | ')}`
        + (perfis.length ? `\n  perfil dos leads - ${perfis.join(', ')}` : '');
    });

    return [
      `Criativos (${r?.resumo?.criativos || 0} no total):`,
      r?.pergunta ? `O perfil vem da pergunta: "${r.pergunta}"` : '',
      Number(q.quantos)
        ? `\nATENCAO: ${q.quantos} criativo(s) rodando sem trazer lead, `
          + `${reais(q.gasto)} gastos.`
        : '',
      '',
      ...linhas,
      anuncios.length >= 25 ? '\n(os 25 com mais leads)' : '',
    ].filter(Boolean).join('\n');
  }

  if (nome === 'conjuntos_do_criativo') {
    const r = await db.rpc('dash_anuncio_conjuntos', {
      p: { chave: args?.chave || '', lancamento: lanc() },
    });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const cs: any[] = r?.conjuntos || [];
    if (!cs.length) return `Nenhum conjunto para o criativo "${args?.chave}".`;

    return [
      `Criativo "${r?.chave}" nos conjuntos:`,
      '',
      ...cs.map((c: any) => {
        const pedacos = [
          `${c.leads} leads`, `${c.engenheiros} engenheiros`,
        ];
        if (c.gasto) pedacos.push(`${reais(c.gasto)} investido`);
        if (c.cpl_engenheiro != null) pedacos.push(`CPL eng ${reais(c.cpl_engenheiro)}`);
        pedacos.push(c.ativo ? 'ativo' : 'pausado');
        if (c.queimando) pedacos.push('*** GASTOU SEM TRAZER LEAD ***');

        return `- ${c.conjunto}\n  ${pedacos.join(' | ')}`
          + (c.campanha ? `\n  campanha: ${c.campanha}` : '');
      }),
    ].join('\n');
  }

  if (nome === 'captacao_dia_a_dia') {
    const dias = Math.min(Math.max(Number(args?.dias) || 30, 1), 180);
    const r = await db.rpc('dash_serie_diaria', {
      p: { dias, lancamento: lanc() },
    });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const dd: any[] = r?.dados || [];
    if (!dd.length) return 'Sem dados no periodo.';

    return [
      `Captacao dia a dia (${dd.length} dias):`,
      '',
      ...dd.map((d: any) =>
        `${d.dia}: ${d.leads} leads, ${d.engenheiros} engenheiros`
        + (d.investido ? `, ${reais(d.investido)} investido` : '')
        + (d.cpl != null ? `, CPL ${reais(d.cpl)}` : '')),
    ].join('\n');
  }

  // ---------- leads ----------
  if (nome === 'funil_de_leads') {
    const r = await db.rpc('dash_grupo', { p: { lancamento: lanc() } });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const leads = Number(r?.leads || 0);
    const taxa = (n: any) => (leads > 0 && n != null
      ? ` (${Math.round(100 * Number(n) / leads)}% dos leads)` : '');

    return [
      'Funil da captacao:',
      `- Leads capturados: ${num(r?.leads)}`,
      `- Fizeram o quiz: ${num(r?.fizeram_quiz)}${taxa(r?.fizeram_quiz)}`,
      `- Clicaram no link do grupo: ${num(r?.clicaram)}${taxa(r?.clicaram)}`,
      `- No grupo do WhatsApp: ${num(r?.no_grupo)}`
        + (r?.pct_no_grupo != null ? ` (${r.pct_no_grupo}% dos leads)` : ''),
      r?.engenheiros_entraram != null
        ? `- Engenheiros no grupo: ${r.engenheiros_entraram}` : '',
      '',
      'O total no grupo vem do SendFlow e conta todo mundo que esta la,',
      'inclusive quem entrou com telefone diferente do formulario.',
    ].filter(Boolean).join('\n');
  }

  if (nome === 'perfil_da_base') {
    const r = await db.rpc('perfil_da_base', { p: { lancamento: lanc() } });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const pp: any[] = r?.perguntas || [];
    if (!pp.length) return 'Nenhuma resposta de quiz neste lancamento.';

    return [
      `Perfil da base (${r?.leads_no_lancamento || 0} leads no lancamento):`,
      '',
      ...pp.map((q: any) => {
        const respostas = (q.respostas || []).map((x: any) =>
          `    ${x.resposta}: ${x.leads} (${x.pct}%)`);
        return `${q.pergunta}\n  ${q.responderam} responderam\n`
          + respostas.join('\n');
      }),
    ].join('\n\n');
  }

  if (nome === 'buscar_lead') {
    const r = await db.rpc('buscar_lead', { p: { busca: args?.busca || '' } });
    if (r?.ok === false) return String(r?.erro || 'falhou');
    if (!r?.encontrado) return String(r?.aviso || 'nenhum lead com esse contato');

    const parts: any[] = r?.participacoes || [];
    const compras: any[] = r?.compras || [];

    return [
      `${r.nome || '(sem nome)'}`,
      `e-mail: ${r.email || '-'} | telefone: ${r.telefone || '-'}`,
      `cadastrado em ${r.cadastrado_em || '-'}`,
      '',
      'Participacoes:',
      ...parts.map((p: any) => {
        const marcas = [
          p.engenheiro ? 'engenheiro' : '',
          p.fez_quiz ? 'fez o quiz' : 'nao fez o quiz',
          p.entrou_no_grupo ? 'entrou no grupo' : 'nao entrou no grupo',
        ].filter(Boolean);
        const resp = p.respostas
          ? Object.entries(p.respostas).map(([k, v]) => `${k}=${v}`).join(', ')
          : '';
        return `- ${p.lancamento} (${p.capturado_em}): ${marcas.join(', ')}`
          + (p.origem ? `\n  origem: ${p.origem}` : '')
          + (resp ? `\n  respostas: ${resp}` : '');
      }),
      compras.length ? '\nCompras:' : '\nNenhuma compra.',
      ...compras.map((c: any) =>
        `- ${c.produto} | ${reais(c.valor)} | ${c.status} | ${c.quando}`),
    ].filter(Boolean).join('\n');
  }

  if (nome === 'recuperacao_vendas') {
    const r = await db.rpc('recuperacao_vendas', {
      p: {
        lancamento: lanc(),
        motivos: Array.isArray(args?.motivos) ? args.motivos : [],
        plataformas: Array.isArray(args?.plataformas) ? args.plataformas : [],
        so_com_telefone: !!args?.so_com_telefone,
        limite: 120,
      },
    });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const tot = r?.total || {};
    const motivos: any[] = r?.por_motivo || [];
    const lista: any[] = r?.lista || [];

    const porMotivo = motivos.map((m: any) => {
      const pedacos = [`${m.quantos} pessoa(s)`, reais(m.valor)];
      if (m.com_telefone != null) pedacos.push(`${m.com_telefone} com telefone`);
      if (m.engenheiros) pedacos.push(`${m.engenheiros} engenheiros`);
      return `- ${m.rotulo}: ${pedacos.join(' | ')}`
        + (m.recuperavel === false ? ' [não se recupera com mensagem]' : '')
        + `\n  o que fazer: ${m.acao}`;
    });

    const pessoas = lista.map((p: any) => {
      const pedacos = [
        p.rotulo,
        reais(p.valor),
        `há ${p.dias} dia(s)`,
        p.plataforma,
      ];
      if (p.engenheiro) pedacos.push('engenheiro');
      if (!p.telefone) pedacos.push('SEM TELEFONE');
      if (p.tentativas > 1) pedacos.push(`${p.tentativas} tentativas`);
      if (p.comprou_outro) pedacos.push('já comprou outro produto');
      if (p.ja_enviado) pedacos.push(`já recebeu hoje: ${p.ja_enviado.join(', ')}`);

      return `- ${p.nome || '(sem nome)'} — ${pedacos.join(' | ')}`
        + (p.situacao ? `\n  status na plataforma: ${p.situacao}` : '');
    });

    return [
      `Dinheiro em aberto: ${reais(tot.valor)} em ${num(tot.quantos)} pessoa(s)`,
      `Do que vale abordagem: ${reais(tot.valor_recuperavel)} em `
        + `${num(tot.quantos_recuperaveis)} pessoa(s)`,
      tot.com_telefone != null
        ? `Com telefone para WhatsApp: ${tot.com_telefone}` : '',
      tot.sem_contato ? `Sem nenhum contato: ${tot.sem_contato}` : '',
      '',
      'Uma linha por pessoa e por produto. Quem acabou comprando não',
      'está aqui — o cruzamento com as vendas aprovadas já foi feito.',
      '',
      'Por motivo:',
      ...porMotivo,
      '',
      'As pessoas:',
      ...pessoas,
      lista.length >= 120 ? '\n(as 120 mais urgentes)' : '',
    ].filter(Boolean).join('\n');
  }

  // ---------- negócio ----------
  if (nome === 'resumo_lancamento') {
    const r = await db.rpc('dash_resumo_lancamento', {
      p: { lancamento: lanc() },
    });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    return [
      `Lancamento: ${r.lancamento || '-'}`,
      '',
      'Captacao:',
      `- Leads: ${num(r.leads)}`,
      `- Engenheiros: ${num(r.engenheiros)}`
        + (r.pct_engenheiro != null ? ` (${r.pct_engenheiro}% do total)` : ''),
      `- Investido: ${reais(r.investido)}`,
      `- Custo por lead: ${reais(r.cpl)}`,
      `- Custo por engenheiro: ${reais(r.cpl_engenheiro)}`,
      '',
      'Vendas:',
      `- Vendas: ${num(r.vendas)}`,
      `- Compradores: ${num(r.compradores)}`
        + (r.compradores_engenheiros != null
            ? ` (${r.compradores_engenheiros} sao engenheiros)` : ''),
      `- Receita: ${reais(r.receita)}`,
      `- Ticket medio: ${reais(r.ticket)}`,
      `- Conversao: ${pct(r.conversao)}`
        + (r.conversao_engenheiro != null
            ? ` | entre engenheiros: ${r.conversao_engenheiro}%` : ''),
      `- Custo por venda: ${reais(r.cpa)}`,
      `- ROAS: ${r.roas != null ? r.roas + 'x' : '-'}`,
      r.reembolsos ? `- Reembolsos: ${r.reembolsos} (${reais(r.valor_reembolsado)})` : '',
      '',
      'Resultado:',
      `- Liquido: ${reais(r.liquido)}`,
      `- Lucro: ${reais(r.lucro)}`,
      `- Margem: ${pct(r.margem)}`,
      '',
      'Metas:',
      r.meta_leads ? `- Leads: ${r.leads} de ${r.meta_leads}`
        + (r.pct_meta_leads != null ? ` (${r.pct_meta_leads}%)` : '') : '',
      r.meta_faturamento ? `- Faturamento: ${reais(r.receita)} de `
        + `${reais(r.meta_faturamento)}`
        + (r.pct_da_meta != null ? ` (${r.pct_da_meta}%)` : '') : '',
      r.sem_lead ? `\n${r.sem_lead} venda(s) sem lead correspondente na base.` : '',
    ].filter(Boolean).join('\n');
  }

  if (nome === 'vendas') {
    const r = await db.rpc('dash_vendas', { p: { lancamento: lanc() } });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const s = r?.resumo || {};
    const prods: any[] = r?.produtos || [];
    const orig: any[] = r?.origem || [];

    return [
      'Vendas do lancamento:',
      `- Aprovadas: ${num(s.aprovadas)} | Pendentes: ${num(s.pendentes)}`,
      `- Receita bruta: ${reais(s.bruto)} | liquida: ${reais(s.liquido)}`,
      `- Ticket medio: ${reais(s.ticket)}`,
      s.reembolsos ? `- Reembolsos: ${s.reembolsos} (${reais(s.valor_reembolsado)})` : '',
      s.sem_lead ? `- Sem lead correspondente: ${s.sem_lead}` : '',
      prods.length ? '\nPor produto:' : '',
      ...prods.slice(0, 15).map((p: any) =>
        `- ${p.produto || '(sem nome)'}: ${num(p.vendas)} vendas, `
        + `${reais(p.receita)}`),
      orig.length ? '\nDe qual criativo veio a venda:' : '',
      ...orig.slice(0, 12).map((o: any) =>
        `- ${o.anuncio}: ${num(o.vendas)} vendas, ${reais(o.receita)}`
        + (o.engenheiros ? ` (${o.engenheiros} engenheiros)` : '')
        + (o.campanha ? `\n  campanha: ${o.campanha}` : '')),
    ].filter(Boolean).join('\n');
  }

  if (nome === 'aulas') {
    const r = await db.rpc('dash_aulas', { p: { lancamento: lanc() } });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const aa: any[] = r?.aulas || [];
    if (!aa.length) return 'Nenhuma aula cadastrada neste lancamento.';

    return [
      `Aulas de ${r?.lancamento || 'este lancamento'}`
        + (r?.comparando_com ? ` (comparado com ${r.comparando_com})` : ''),
      '',
      ...aa.map((a: any) => {
        const pedacos = [];
        if (a.views != null) pedacos.push(`${a.views} views`);
        if (a.pico != null) pedacos.push(`pico ${a.pico}`);
        if (a.presentes_fim != null) pedacos.push(`${a.presentes_fim} no fim`);
        if (a.retencao_media != null) pedacos.push(`retencao ${a.retencao_media}%`);
        if (a.segurou != null) pedacos.push(`segurou ${a.segurou}%`);
        if (a.comentarios != null) pedacos.push(`${a.comentarios} comentarios`);

        return `- ${a.titulo || a.nome || 'Aula'}: ${pedacos.join(' | ') || 'sem numeros'}`
          + (a.anterior != null
              ? `\n  no lancamento anterior: ${a.anterior} views` : '');
      }),
    ].join('\n');
  }

  // ---------- histórico e saúde ----------
  if (nome === 'comparar_lancamentos') {
    const r = await db.rpc('comparar_lancamentos', { p: {} });
    if (r?.ok === false) return String(r?.erro || 'sem dados');

    const ll: any[] = r?.lancamentos || [];
    if (!ll.length) return 'Nenhum lancamento com dados.';

    return [
      'Lancamentos, do mais recente ao mais antigo:',
      '',
      ...ll.map((l: any) => {
        const pedacos = [
          `${num(l.leads)} leads`,
          `${num(l.engenheiros)} engenheiros`
            + (l.pct_engenheiro != null ? ` (${l.pct_engenheiro}%)` : ''),
        ];
        if (l.investido) pedacos.push(`${reais(l.investido)} investido`);
        if (l.cpl != null) pedacos.push(`CPL ${reais(l.cpl)}`);
        if (l.cpl_engenheiro != null) pedacos.push(`CPL eng ${reais(l.cpl_engenheiro)}`);
        if (l.receita) pedacos.push(`${reais(l.receita)} receita`);
        if (l.vendas) pedacos.push(`${l.vendas} vendas`);
        if (l.roas != null) pedacos.push(`ROAS ${l.roas}x`);
        if (l.conversao != null) pedacos.push(`conversao ${l.conversao}%`);

        return `- ${l.lancamento} (${l.comecou}, ${l.status})\n  `
          + pedacos.join(' | ');
      }),
    ].join('\n');
  }

  if (nome === 'saude_da_dash') {
    const dias = Math.min(Math.max(Number(args?.dias) || 7, 1), 90);

    const [web, fone, anuncios] = await Promise.all([
      db.rpc('diagnostico_webhooks', { p: { dias } }).catch(() => null),
      db.rpc('leads_sem_whatsapp', { p: {} }).catch(() => null),
      db.rpc('dash_anuncios', { p: {} }).catch(() => null),
    ]);

    const problemas: any[] = web?.problemas || [];
    const semZap: any[] = fone?.leads || [];
    const q = anuncios?.queimando || {};

    const linhas: string[] = [];

    if (problemas.length) {
      linhas.push(`Erros de integracao nos ultimos ${dias} dias:`);
      for (const p of problemas) {
        linhas.push(`- ${p.quantos}x ${p.problema}`
          + (p.custa_lead ? ' [CUSTA LEAD]' : ''));
        if (p.o_que_fazer) linhas.push(`  ${p.o_que_fazer}`);
      }
    } else {
      linhas.push(`Nenhum erro de integracao nos ultimos ${dias} dias.`);
    }

    if (Number(q.quantos)) {
      linhas.push('');
      linhas.push(`${q.quantos} criativo(s) rodando sem trazer lead, `
        + `${reais(q.gasto)} gastos.`);
    }

    if (semZap.length) {
      linhas.push('');
      linhas.push(`${semZap.length} lead(s) com telefone que nao tem WhatsApp `
        + '- esses nao recebem mensagem nenhuma.');
    }

    if (web?.ignorados_de_proposito) {
      linhas.push('');
      linhas.push(`(${web.ignorados_de_proposito} eventos ignorados de proposito, `
        + 'que nao sao erro)');
    }

    return linhas.join('\n');
  }

  return `ferramenta desconhecida: ${nome}`;
}

/**
 * O servidor MCP.
 *
 * Atende tanto a revisão nova do protocolo (sem initialize, com os
 * dados no _meta) quanto as antigas, que dependem do initialize. O
 * Claude decide qual usar, e um servidor que só fala uma delas para de
 * conectar quando o cliente muda.
 */
async function mcpServidor(
  req: Request, db: Supabase, env: Env, ch: Record<string, string>,
): Promise<Response> {

  // A versão que o cliente pede vem no header ou no _meta, dependendo
  // da revisão. Sem nenhuma, assume a mais antiga que atendemos.
  const pedidaCab = req.headers.get('mcp-protocol-version') || '';

  const responder = (corpo: any, status = 200, versao?: string) =>
    new Response(JSON.stringify(corpo), {
      status,
      headers: {
        ...ch,
        'content-type': 'application/json',
        // A revisão de 2026 confere se o servidor falou a mesma língua.
        // Sem este header o cliente pode derrubar a conexão.
        ...(versao ? { 'mcp-protocol-version': versao } : {}),
      },
    });

  // GET e DELETE não fazem parte desta revisão do transporte
  if (req.method !== 'POST') {
    return responder({
      jsonrpc: '2.0',
      error: { code: -32601, message: 'use POST' },
    }, 405);
  }

  const corpo: any = await req.json().catch(() => null);
  if (!corpo) {
    return responder({
      jsonrpc: '2.0', id: null,
      error: { code: -32700, message: 'json invalido' },
    }, 400);
  }

  const id = corpo.id ?? null;
  const metodo = String(corpo.method || '');

  // A versão que o cliente pede vem no header ou no _meta, dependendo
  // da revisão. Sem nenhuma, assume a mais antiga que atendemos.
  const pedida = pedidaCab
    || corpo?.params?._meta?.['io.modelcontextprotocol/protocolVersion']
    || corpo?.params?.protocolVersion
    || '2025-03-26';

  const versao = MCP_VERSOES.includes(String(pedida))
    ? String(pedida)
    : MCP_VERSOES[0];

  const ok = (resultado: any) =>
    responder({ jsonrpc: '2.0', id, result: resultado }, 200, versao);

  switch (metodo) {
    case 'initialize':
      return ok({
        protocolVersion: versao,
        capabilities: { tools: {} },
        serverInfo: { name: 'dash-perito', version: '1.0.0' },
        instructions:
          'A dash do Perito da Elétrica, inteira e só leitura: nada aqui '
          + 'altera nada. Cobre conteúdo do Instagram, tráfego pago '
          + '(criativos e conjuntos), o funil de leads, o perfil da base, '
          + 'vendas, aulas, a comparação entre lançamentos e a saúde das '
          + 'integrações.\n\n'
          + 'Duas coisas que mudam a leitura dos números: a taxa de '
          + 'engajamento do Instagram é sobre o ALCANCE, não sobre '
          + 'seguidores — mede se quem viu reagiu; e um criativo marcado '
          + 'como "gastou sem trazer lead" é dinheiro saindo sem retorno, '
          + 'vale avisar sempre que aparecer.\n\n'
          + 'Sobre leads: buscar_lead atende um contato por vez, de '
          + 'propósito. Não existe ferramenta que devolva a base — para '
          + 'ver o retrato dela use perfil_da_base, que traz a '
          + 'distribuição sem nome nem telefone.',
      });

    // notificação: a especificação pede 202 sem corpo
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return new Response(null, { status: 202, headers: ch });

    case 'ping':
      return ok({});

    case 'tools/list':
      return ok({
        // A área é etiqueta nossa, para a tela da dash agrupar. Cliente
        // estrito pode recusar campo fora da especificação, então ela
        // não vai pro fio.
        tools: mcpFerramentas().map(({ area, ...f }) => f),
      });

    case 'tools/call': {
      const nome = String(corpo?.params?.name || '');
      try {
        const texto = await mcpChamar(
          nome, corpo?.params?.arguments || {}, db, env,
        );
        return ok({ content: [{ type: 'text', text: texto }] });
      } catch (e: any) {
        // erro dentro da ferramenta volta como resultado com isError,
        // não como erro de protocolo: o modelo consegue explicar ao
        // usuário em vez de a conversa quebrar
        return ok({
          content: [{
            type: 'text',
            text: `falhou: ${String(e?.message || e).slice(0, 300)}`,
          }],
          isError: true,
        });
      }
    }

    // pedidos que não atendemos, mas que alguns clientes fazem na
    // abertura: devolver vazio evita erro na tela do cliente
    case 'resources/list':
      return ok({ resources: [] });
    case 'prompts/list':
      return ok({ prompts: [] });

    default:
      return responder({
        jsonrpc: '2.0', id,
        error: { code: -32601, message: `metodo nao atendido: ${metodo}` },
      }, 404);
  }
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

      // ---- o conector MCP: /mcp/{segredo}
      //
      // Não passa pelo login da dash, porque o Claude não tem sessão
      // aqui. A URL é a credencial, como nos webhooks.
      if (partes[0] === 'mcp') {
        const segredo = (env.MCP_SEGREDO || '').trim();

        // sem segredo configurado a rota não existe: melhor 404 do que
        // um conector aberto por esquecimento
        if (!segredo) {
          return new Response('nao configurado', { status: 404 });
        }

        if (partes[1] !== segredo) {
          return new Response('nao autorizado', { status: 401 });
        }

        return mcpServidor(req, db, env, ch);
      }

      if (partes[0] === 'health') {
        return jsonResponse({
          ok: true,
          ts: new Date().toISOString(),
          config: {
            supabase_url: !!env.SUPABASE_URL,
            supabase_key: !!env.SUPABASE_SERVICE_KEY,
            anon_key: !!env.SUPABASE_ANON_KEY,
            versao: 'v108-whatsapp-manual',
            webhook_secret: env.WEBHOOK_SECRET ? `${env.WEBHOOK_SECRET.length} chars` : false,
            debug_token: !!env.DEBUG_TOKEN,
            lancamento_padrao: env.LANCAMENTO_PADRAO || false,
            sellflux_endpoint: env.SELLFLUX_ENDPOINT ? 'configurado' : 'nao configurado',
            conector_mcp: env.MCP_SEGREDO ? 'configurado' : 'nao configurado',
            // os dois destinos, para conferir de relance qual é qual
            destino_captacao: (await destinoSellflux('captacao', db, env)).fonte,
            destino_reativacao: (await destinoSellflux('reativacao', db, env)).fonte,
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
          lancamento: s(body?.lancamento) || await slugAtivo(db, env),
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
        ctx.waitUntil(repassar(dados, env, db, r?.pessoa_id));

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

        // A Hotmart assina cada webhook com o hottok. Sem conferir, quem
        // descobrir a URL poderia inventar vendas no seu faturamento.
        // A TMB deixa você escolher o nome e o valor do header de
        // autenticação. Usamos x-dash-token com o mesmo segredo da URL.
        if (fonte === 'tmb' || fonte === 'tmb-financeiro') {
          const guardado = await segredoIntegracao('tmb', 'header_valor', db);
          const esperado = guardado?.valor || '';
          if (esperado) {
            const recebido = req.headers.get('x-dash-token') || '';
            if (recebido !== esperado) {
              return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
            }
          }
        }

        if (fonte === 'hotmart') {
          const guardado = await segredoIntegracao('hotmart', 'hottok', db);
          const esperado = guardado?.valor || env.HOTMART_HOTTOK || '';
          const recebido = req.headers.get('x-hotmart-hottok')
            || s(achar(body, ['hottok'])) || '';
          if (esperado && recebido !== esperado) {
            await db.insert('webhooks_raw', {
              fonte: 'hotmart_hottok_invalido', headers, body,
              processado: false, erro: 'hottok nao confere',
            }).catch(() => {});
            return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
          }
        }

        const lancDaUrl = url.searchParams.get('l')
          || url.searchParams.get('lancamento');
        if (lancDaUrl) headers['x-dash-lancamento'] = lancDaUrl;

        const raw = await db.insert('webhooks_raw', { fonte, headers, body, processado: false }, 'dash');
        const rawId = raw?.[0]?.id ?? null;

        // ?l=slug amarra este webhook a um lançamento específico
        const lancWebhook = url.searchParams.get('l')
          || url.searchParams.get('lancamento')
          || undefined;
        ctx.waitUntil(processar(fonte, body, rawId, db, env, lancWebhook));
        return jsonResponse({ ok: true, recebido: true, raw_id: rawId }, 200, ch);
      }

      // ---------------- REDIRECT PRO GRUPO
      //
      // Duas formas convivem: /r/grupo/<segredo> é a antiga, usada em
      // links já espalhados; /r/grupo/publico é a que o quiz monta, e
      // ela é tratada logo abaixo. Sem esta exceção, a rota antiga
      // compara "publico" com o segredo e devolve 403.
      if (partes[0] === 'r' && partes[1] === 'grupo' && partes[2] !== 'publico') {
        if ((partes[2] || '') !== env.WEBHOOK_SECRET) {
          return new Response('Link inválido.', { status: 403 });
        }
        const inscricaoId = url.searchParams.get('i');
        const slug = url.searchParams.get('l') || await slugAtivo(db, env);

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

      // ============ PÁGINA DO QUIZ ============
      if (partes[0] === 'q') {
        const inscricao = url.searchParams.get('i') || '';
        // a inscrição decide de qual lançamento é este quiz
        const slug = await slugDaInscricao(inscricao, db)
          || url.searchParams.get('l')
          || await slugAtivo(db, env);
        return new Response(paginaQuiz(slug, inscricao, url.origin), {
          headers: {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-store',
          },
        });
      }

      // ============ WIDGET DA LP ============
      if (partes[0] === 'embed.js') {
        const slug = url.searchParams.get('l') || await slugAtivo(db, env);

        // a página de quiz é configurada por lançamento; sem ela o quiz
        // continua acontecendo dentro da landing
        const lancEmbed = await db.select('lancamentos',
          { select: 'config', slug: `eq.${slug}`, limit: '1' });
        const paginaQuiz = url.searchParams.get('quiz')
          || lancEmbed?.[0]?.config?.pagina_quiz
          || env.PAGINA_QUIZ
          || '';

        return new Response(widgetJS(slug, url.origin, paginaQuiz), {
          headers: {
            'Content-Type': 'application/javascript; charset=utf-8',
            // curto: o cliente não precisa limpar cache ao mexer no quiz
            'Cache-Control': 'public, max-age=300',
            'Access-Control-Allow-Origin': '*',
          },
        });
      }

      // link do grupo sem expor o segredo do webhook na landing
      if (partes[0] === 'r' && partes[1] === 'grupo' && partes[2] === 'publico') {
        const inscricaoId = url.searchParams.get('i');
        let lanc: any = null;

        // A inscrição decide. O grupo é do lançamento em que a pessoa
        // se inscreveu, e nenhum outro — o slug na URL pode estar
        // errado, e "o ativo" é chute quando há mais de um.
        if (inscricaoId && inscricaoId !== 'undefined') {
          const dono = await db.select('inscricoes', {
            select: 'lancamento_id', id: `eq.${inscricaoId}`, limit: '1',
          }).catch(() => null);

          const lancId = dono?.[0]?.lancamento_id;
          if (lancId) {
            lanc = await db.select('lancamentos', {
              select: 'id,slug,config', id: `eq.${lancId}`, limit: '1',
            }).catch(() => null);
          }
        }

        // sem inscrição, resta o slug da URL
        if (!lanc?.[0]) {
          const slug = url.searchParams.get('l');
          if (slug) {
            lanc = await db.select('lancamentos',
              { select: 'id,slug,config', slug: `eq.${slug}`, limit: '1' });
          }
        }

        let destino = lanc?.[0]?.config?.grupo_url;

        if (!destino) {
          return new Response(
            'O link do grupo não está cadastrado neste lançamento. '
            + 'Configure em Quiz > Para onde o lead vai ao terminar.',
            { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } },
          );
        }

        // link colado sem https quebra o redirect com erro genérico
        destino = String(destino).trim();
        if (!/^https?:\/\//i.test(destino)) destino = `https://${destino}`;

        try {
          new URL(destino);
        } catch {
          return new Response(
            `O link cadastrado não é um endereço válido: ${destino}`,
            { status: 400, headers: { 'content-type': 'text/plain; charset=utf-8' } },
          );
        }

        if (inscricaoId && inscricaoId !== 'undefined') {
          ctx.waitUntil(db.rpc('ingest_evento', {
            p: { inscricao_id: inscricaoId, tipo: 'grupo_click', fonte: 'interno',
                 lancamento: lanc[0].slug, payload: {} },
          }).catch(() => {}));
        }
        return Response.redirect(destino, 302);
      }

      // ============ /r/tmb/:inscricao — link do financiamento ============
      //
      // A TMB só cria pedido quando a pessoa termina o cadastro. Quem
      // clicou e desistiu antes disso não aparece em nenhuma API dela.
      //
      // Passando o link por aqui, a dash grava o clique e consegue
      // dizer quem foi até lá e nunca começou — o ponto mais cedo em
      // que dá para recuperar essa venda.
      if (partes[0] === 'r' && partes[1] === 'tmb') {
        const inscricaoId = partes[2] || url.searchParams.get('i') || '';

        let lanc = inscricaoId && inscricaoId !== 'undefined'
          ? await db.select('inscricoes', {
            select: 'lancamento_id,lancamentos(slug,config)',
            id: `eq.${inscricaoId}`, limit: '1',
          }).catch(() => null)
          : null;

        let slugLanc = lanc?.[0]?.lancamentos?.slug || '';
        let destino = lanc?.[0]?.lancamentos?.config?.financiamento_url;

        // sem inscrição na URL, ou inscrição que não existe: cai no
        // lançamento pedido por ?l= ou no ativo
        if (!destino) {
          const pedido = url.searchParams.get('l');
          const l2 = pedido
            ? await db.select('lancamentos',
              { select: 'slug,config', slug: `eq.${pedido}`, limit: '1' })
            : await db.select('lancamentos', {
              select: 'slug,config',
              status: 'in.(captacao,aquecimento,evento,carrinho)',
              order: 'criado_em.desc', limit: '1',
            });
          slugLanc = l2?.[0]?.slug || slugLanc;
          destino = l2?.[0]?.config?.financiamento_url;
        }

        if (!destino) {
          return new Response(
            'O link do financiamento não está cadastrado neste lançamento. '
            + 'Configure em Recuperação de Vendas > Link do financiamento.',
            { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } },
          );
        }

        destino = String(destino).trim();
        if (!/^https?:\/\//i.test(destino)) destino = `https://${destino}`;

        try {
          new URL(destino);
        } catch {
          return new Response(
            `O link cadastrado não é um endereço válido: ${destino}`,
            { status: 400, headers: { 'content-type': 'text/plain; charset=utf-8' } },
          );
        }

        // O clique é gravado depois da resposta: a pessoa vai para a TMB
        // na hora, mesmo se o banco estiver lento.
        if (inscricaoId && inscricaoId !== 'undefined' && slugLanc) {
          ctx.waitUntil(db.rpc('ingest_evento', {
            p: {
              inscricao_id: inscricaoId, tipo: 'tmb_click', fonte: 'interno',
              lancamento: slugLanc, payload: {},
            },
          }).catch(() => {}));
        }
        return Response.redirect(destino, 302);
      }

      // ============ QUIZ (público — o lead responde) ============
      if (partes[0] === 'quiz' && req.method === 'GET') {
        // as perguntas são as do lançamento do lead, não as do ativo
        const slug = await slugDaInscricao(url.searchParams.get('i'), db)
          || url.searchParams.get('l')
          || await slugAtivo(db, env);
        const r = await db.rpc('quiz_publico', { p: { lancamento: slug } });
        return jsonResponse(r, r?.ok === false ? 404 : 200, ch);
      }

      if (partes[0] === 'quiz' && req.method === 'POST') {
        const corpo: any = await safeJson(req);

        // mesma proteção da captura: campo isca e tempo mínimo
        if (s(corpo?.empresa) || s(corpo?.website)) {
          return jsonResponse({ ok: true, recebido: true }, 200, ch);
        }

        // O lançamento vem da inscrição, não do "lançamento ativo".
        // O quiz é configurado por lançamento: se o lead entrou no X,
        // as perguntas, o grupo e a atribuição são do X — mesmo que
        // outro lançamento tenha começado enquanto ele respondia, e
        // mesmo com dois ativos ao mesmo tempo.
        const r = await db.rpc('responder_quiz', {
          p: {
            inscricao_id: s(corpo?.inscricao_id),
            email: s(corpo?.email),
            telefone: s(corpo?.telefone),
            lancamento: s(corpo?.lancamento),
            respostas: corpo?.respostas || {},
          },
        });
        if (r?.ok === false) return jsonResponse(r, 400, ch);

        // O evento do Meta sai aqui: é agora que sabemos se o lead se
        // qualificou. Vai em segundo plano — o lead não pode esperar a
        // resposta do Meta para ser mandado ao grupo.
        if (r?.inscricao_id) {
          ctx.waitUntil(
            enviarEventosMeta(String(r.inscricao_id), db, env).catch(() => {}),
          );
        }

        // O link do grupo passa por uma rota nossa para registrar o
        // clique. Sem inscricao_id o parâmetro virava "undefined" e a
        // rota respondia erro — melhor mandar sem ele do que quebrar.
        // O link leva a inscrição; a rota do grupo resolve o lançamento
        // a partir dela. O slug vai junto só para o registro do clique.
        const slug = s(corpo?.lancamento) || '';
        const link = `${url.origin}/r/grupo/publico`
                   + `?l=${encodeURIComponent(slug)}`
                   + (r?.inscricao_id ? `&i=${r.inscricao_id}` : '');
        return jsonResponse({ ...r, grupo_url: link }, 200, ch);
      }

      // ============ SINCRONIZAÇÃO MANUAL DA TMB ============
      if (partes[0] === 'sync' && partes[1] === 'tmb') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
        }
        const dias = Math.min(180, Number(url.searchParams.get('dias') || 30));
        const r = await sincronizarTMB(dias, db, env);
        return jsonResponse(r, r.ok ? 200 : 400, ch);
      }

      // ============ SINCRONIZAÇÃO MANUAL DO META ============
      if (partes[0] === 'sync' && partes[1] === 'meta') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401, ch);
        }
        const slug = url.searchParams.get('lancamento') || await slugAtivo(db, env);
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
        // filtro de produtos vem como ?produtos=A|B|C
        const produtos = (url.searchParams.get('produtos') || '')
          .split('|').map((x) => x.trim()).filter(Boolean);

        // -------- lançamentos
        if (partes[1] === 'quiz' && req.method === 'GET') {
          const r = await db.rpc('quiz_admin', { p: { lancamento: slug } });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'quiz-copiar' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('copiar_quiz', {
            p: { destino: slug, origem: corpo.origem || null },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'quiz' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          // o lançamento vem na URL, não no corpo: sem juntar aqui, a
          // função não acha o lançamento e recusa o salvamento inteiro
          const r = await db.rpc('salvar_quiz', {
            p: { ...corpo, lancamento: corpo.lancamento || slug },
          });

          // a página do quiz vive no mesmo formulário, mas em outra
          // função: salvar as duas juntas evita um botão a mais na tela
          if (corpo.pagina_quiz !== undefined) {
            await db.rpc('salvar_pagina_quiz', {
              p: { lancamento: corpo.lancamento || slug,
                   pagina_quiz: corpo.pagina_quiz },
            }).catch(() => {});
          }

          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'sugerir-codigo') {
          const r = await db.rpc('sugerir_codigo', {
            p: { captacao_inicio: url.searchParams.get('inicio') || null },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'alterar-codigo' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('alterar_codigo', {
            p: { ...corpo, lancamento: corpo.lancamento || slug },
          });
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
            db.rpc('dash_receita', { p: { inicio, fim, produtos } }),
            db.rpc('dash_captura', { p: { lancamento: slug } }),
            db.rpc('dash_serie_diaria', { p: { lancamento: slug, dias } }),
          ]);

          return jsonResponse({ ok: true, usuario, receita, captura, serie }, 200, ch);
        }

        // -------- lista de leads
        if (partes[1] === 'sincronizar' && partes[2] === 'historico') {
          const r = await sincronizarHistorico(slug, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'sincronizar-investimento') {
          const r = await sincronizarInvestimento(db, env, {
            de: url.searchParams.get('de') || '',
            ate: url.searchParams.get('ate') || '',
            todas: url.searchParams.get('todas') === '1',
          });
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'upload' && req.method === 'POST') {
          return await subirImagem(req, env, ch);
        }

        if (partes[1] === 'lancamentos-com-leads') {
          const r = await db.rpc('lancamentos_com_leads', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'push' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = corpo.remover
            ? await db.rpc('remover_push', { p: corpo })
            : await db.rpc('salvar_push', {
                p: { ...corpo, user_agent: req.headers.get('user-agent') || '' },
              });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'push') {
          const r = await db.rpc('push_estado', { p: {} });
          // a chave pública vai junto: o navegador precisa dela para
          // criar a inscrição, e ela não é segredo
          return jsonResponse({ ...r, chave: env.VAPID_PUBLIC_KEY || '' }, 200, ch);
        }

        if (partes[1] === 'push-config' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_push_config', { p: corpo });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'push-testar' && req.method === 'POST') {
          const r = await avisarCaptacao(db, env, true);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'modelos-email' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = url.searchParams.get('apagar') === '1'
            ? await db.rpc('apagar_modelo_email', { p: corpo })
            : await db.rpc('salvar_modelo_email', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'modelos-email') {
          const r = await db.rpc('modelos_email', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'eventos-meta' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_eventos_meta', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'eventos-meta') {
          const r = await db.rpc('config_eventos_meta', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'testar-evento-meta' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));

          // Sem inscrição escolhida, usa o último lead que respondeu o
          // quiz: é o que a pessoa quer testar na prática, e procurar o
          // id na mão só atrasa.
          let insc = String(corpo.inscricao_id || '').trim();

          if (!insc) {
            const ultimo = await db.rpc('ultimo_lead_do_quiz', { p: {} })
              .catch(() => null);
            insc = ultimo?.inscricao_id || '';
            if (!insc) {
              return jsonResponse({
                ok: false,
                erro: 'nenhum lead respondeu o quiz ainda. '
                    + 'Faça um lead de teste primeiro.',
              }, 400, ch);
            }
          }

          // reenviar de propósito: o registro anterior não pode barrar
          if (corpo.forcar) {
            await db.rpc('limpar_envio_meta', { p: { inscricao_id: insc } })
              .catch(() => {});
          }

          const r = await enviarEventosMeta(insc, db, env);
          return jsonResponse({ ...r, inscricao_id: insc }, r.ok ? 200 : 400, ch);
        }

        // qual webhook a reativação vai usar, para a tela mostrar
        // antes de mandar
        if (partes[1] === 'reativar-destino') {
          const d = await destinoSellflux('reativacao', db, env);
          return jsonResponse({
            ok: !!d.url,
            nome: d.nome,
            fonte: d.fonte,
            // só o final, o suficiente para reconhecer sem expor a URL
            final: d.url ? String(d.url).slice(-12) : null,
          }, 200, ch);
        }

        if (partes[1] === 'reativar-fila' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('enfileirar_reativacao', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'reativar-status') {
          const r = await db.rpc('fila_reativacao_status', {
            p: { campanha: url.searchParams.get('campanha') || '' },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'reativar-cancelar' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('fila_reativacao_cancelar', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        // empurra a fila na hora, sem esperar o cron
        if (partes[1] === 'reativar-empurrar' && req.method === 'POST') {
          const r = await processarFilaReativacao(db, env, 40);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'ads-conjunto') {
          const r = await lerConjuntoMeta(
            url.searchParams.get('id') || '', env,
          );
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'ads-orcamento' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await mudarOrcamento(corpo, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'ads-duplicar' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await duplicarConjunto(corpo, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'ads-status' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await mudarStatusAds(corpo, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'anuncio-conjuntos' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('dash_anuncio_conjuntos', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        // o link do conector, pronto para colar no Claude
        //
        // Montado aqui e não na tela porque o segredo vive no Worker.
        // Só quem está logado na dash chega nesta rota.
        if (partes[1] === 'conector') {
          const segredo = (env.MCP_SEGREDO || '').trim();

          if (!segredo) {
            return jsonResponse({
              ok: false,
              erro: 'o conector ainda nao foi configurado. Crie a variavel '
                  + 'MCP_SEGREDO no Worker (Settings > Variables and Secrets, '
                  + 'tipo Secret) com um texto longo e aleatorio.',
            }, 200, ch);
          }

          return jsonResponse({
            ok: true,
            url: `${url.origin}/mcp/${segredo}`,
            // Treze itens em lista corrida é um muro. Agrupados por
            // área, a pessoa vê o alcance do conector de relance.
            areas: mcpFerramentas().reduce((acc: any[], f: any) => {
              let g = acc.find((x) => x.area === f.area);
              if (!g) { g = { area: f.area, ferramentas: [] }; acc.push(g); }
              g.ferramentas.push({
                nome: f.name,
                // a primeira frase basta para a tela; a descrição
                // inteira é escrita para o modelo, não para a pessoa
                resumo: String(f.description).split('. ')[0] + '.',
              });
              return acc;
            }, []),
          }, 200, ch);
        }

        if (partes[1] === 'ig-contas') {
          const r = await igContasDisponiveis(env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'ig-conectar' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('ig_salvar_conta', { p: corpo });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'ig-sincronizar' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await igSincronizar(corpo, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'instagram') {
          const r = await db.rpc('dash_instagram', {
            p: {
              de: url.searchParams.get('de') || '',
              ate: url.searchParams.get('ate') || '',
              tipo: url.searchParams.get('tipo') || '',
              ordem: url.searchParams.get('ordem') || 'data',
            },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'ig-analise') {
          const r = await db.rpc('ig_analise', {
            p: { dias: url.searchParams.get('dias') || '' },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'exportar-opcoes' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('opcoes_exportar', { p: corpo });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'exportar-previa' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('previa_exportar_leads', { p: corpo });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'exportar-csv' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('exportar_leads', { p: corpo });

          if (r?.ok === false) return jsonResponse(r, 400, ch);

          const leads: any[] = r?.leads || [];

          // Três colunas é o padrão: a lista costuma ir para uma
          // ferramenta de envio, e coluna a mais atrapalha o
          // mapeamento na importação.
          const colunas = corpo?.completo
            ? ['nome', 'email', 'telefone', 'lancamento', 'perfil',
               'engenheiro', 'comprou', 'capturado_em']
            : ['nome', 'email', 'telefone'];

          const csv = montarCsv(leads, colunas);

          return new Response(csv, {
            status: 200,
            headers: {
              ...ch,
              'content-type': 'text/csv; charset=utf-8',
              'x-total-leads': String(leads.length),
            },
          });
        }

        if (partes[1] === 'opcoes-segmentacao' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('opcoes_segmentacao', { p: corpo });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'previa-reativacao' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('previa_reativacao', { p: corpo });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'reativar' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await enviarReativacao(corpo, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'historico-reativacao') {
          const r = await db.rpc('historico_reativacao', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'grupo') {
          const r = await db.rpc('dash_grupo', { p: { lancamento: slug } });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'leads-grupo') {
          const r = await db.rpc('leads_grupo', {
            p: { lancamento: slug, filtro: url.searchParams.get('filtro') || '' },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'marcar-grupo' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('marcar_entrada_grupo', {
            p: { lancamento: slug, telefones: corpo.telefones || [] },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'pendentes') {
          const r = await db.rpc('pagamentos_pendentes', { p: { lancamento: slug } });
          return jsonResponse(r, 200, ch);
        }

        // ---- a tela de Recuperação de Vendas
        //
        // Sem `tudo=false` na URL, vem tudo em aberto do lançamento sem
        // filtro de data: boleto do carrinho anterior continua sendo
        // dinheiro na mesa.
        if (partes[1] === 'recuperacao') {
          const lista = (nome: string) => {
            const v = url.searchParams.get(nome) || '';
            return v ? v.split(',').map((x) => x.trim()).filter(Boolean) : [];
          };

          // A lista vem pela recuperacao_lista_mensagens: é a mesma
          // recuperacao_vendas, com a mensagem do motivo já preenchida
          // e o telefone em dígitos para o link do WhatsApp.
          const r = await db.rpc('recuperacao_lista_mensagens', {
            p: {
              lancamento: slug,
              motivos: lista('motivos'),
              plataformas: lista('plataformas'),
              de: url.searchParams.get('de') || '',
              ate: url.searchParams.get('ate') || '',
              tudo: url.searchParams.get('tudo') !== 'false',
              so_com_telefone: url.searchParams.get('so_com_telefone') === 'true',
              incluir_comprou: url.searchParams.get('incluir_comprou') === 'true',
              limite: Number(url.searchParams.get('limite') || 500),
            },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }


        // ---- as mensagens prontas, uma por motivo
        if (partes[1] === 'mensagens-recuperacao' && req.method === 'GET') {
          const r = await db.rpc('mensagens_recuperacao', { p: {} });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'mensagens-recuperacao' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_mensagem_recuperacao', {
            p: { motivo: corpo.motivo || '', texto: corpo.texto || '',
                 quem: usuario },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        // ---- o status e o rascunho de quem chamou
        //
        // Manda só o campo que mudou: o `p ? 'status'` do lado do banco
        // distingue "não mexi nisso" de "quis apagar". Mandando os dois
        // sempre, mudar o seletor limparia a nota.
        if (partes[1] === 'nota-recuperacao' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const p: any = { venda_id: corpo.venda_id || '' };
          if ('status' in corpo) p.status = corpo.status ?? '';
          if ('nota' in corpo) p.nota = corpo.nota ?? '';
          const r = await db.rpc('salvar_nota_recuperacao', { p });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        // quem clicou no link do financiamento e nunca abriu pedido
        if (partes[1] === 'financiamento-cliques') {
          const r = await db.rpc('clicou_financiamento', { p: { lancamento: slug } });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'link-financiamento' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_link_financiamento', {
            p: { lancamento: slug, url: corpo.url || '' },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }


        if (partes[1] === 'historico-recuperacao') {
          const r = await db.rpc('historico_recuperacao', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'contas-meta' && req.method === 'POST') {
          const corpo = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_contas_meta', {
            p: { contas: (corpo as any).contas || '' },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'contas-meta') {
          const r = await db.rpc('contas_meta', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'webhooks-pendentes') {
          const r = await db.rpc('webhooks_pendentes', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'reprocessar') {
          const r = await db.rpc('reprocessar_vendas', {
            p: {
              fonte: url.searchParams.get('fonte') || '',
              limite: Number(url.searchParams.get('limite') || 500),
            },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'origem-investimento') {
          const r = await db.rpc('investimento_por_origem', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'limpar-investimento' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          // sem lançamento no corpo, limpa o do seletor; o front manda
          // vazio de propósito quando quer limpar tudo
          const r = await db.rpc('limpar_investimento', {
            p: {
              origem: corpo.origem || 'tudo',
              lancamento: corpo.lancamento === '' ? '' : (corpo.lancamento || slug),
            },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'sem-investimento') {
          const r = await db.rpc('lancamentos_sem_investimento', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'buscar-campanhas') {
          const r = await buscarCampanhasPeriodo(slug, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'campanhas-candidatas') {
          const r = await db.rpc('candidatas_do_lancamento', { p: { lancamento: slug } });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'escolher-campanhas' && req.method === 'POST') {
          const corpo = await req.json().catch(() => ({}));
          const r = await db.rpc('escolher_campanhas', {
            p: { lancamento: slug, ids: (corpo as any).ids || [] },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'importar-campanhas') {
          const r = await importarCampanhasEscolhidas(slug, db, env);
          return jsonResponse(r, r.ok ? 200 : 400, ch);
        }

        if (partes[1] === 'modelos-quiz') {
          const r = await db.rpc('modelos_quiz', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'aplicar-modelo' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('aplicar_modelo_quiz', {
            p: { lancamento: slug, modelo: corpo.modelo || '', substituir: 'sim' },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'salvar-modelo' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_modelo_quiz', {
            p: {
              lancamento: slug,
              nome: corpo.nome || '',
              descricao: corpo.descricao || '',
              padrao: !!corpo.padrao,
            },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'quiz-disponivel') {
          const r = await db.rpc('quiz_disponivel', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'gasto-meta') {
          const r = await db.rpc('gasto_meta', { p: { lancamento: slug } });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'ads-sem-gasto') {
          const r = await db.rpc('ads_sem_gasto', { p: { lancamento: slug } });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'sincronizar' && partes[2]) {
          const alvo = partes[2];
          if (alvo === 'tmb') {
            const r = await sincronizarTMB(30, db, env);
            return jsonResponse(r, r.ok ? 200 : 400, ch);
          }
          if (alvo === 'meta') {
            const r = await sincronizarMeta(slug || env.LANCAMENTO_PADRAO || '', 30, db, env);
            return jsonResponse(r, r.ok ? 200 : 400, ch);
          }
          return jsonResponse({ ok: false, erro: 'sem sincronizacao para ' + alvo }, 400, ch);
        }

        if (partes[1] === 'integracoes' && req.method === 'GET') {
          const r = await db.rpc('dash_integracoes', { p: {} });
          return jsonResponse({ ...r, webhook_base: url.origin,
                                webhook_secret: env.WEBHOOK_SECRET }, 200, ch);
        }

        if (partes[1] === 'integracoes' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_integracao', { p: corpo });
          cacheSegredo.clear();   // muda a config, invalida o que estava guardado
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'aulas' && req.method === 'GET') {
          const r = await db.rpc('dash_aulas', { p: { lancamento: slug } });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'aulas-historico') {
          const r = await db.rpc('dash_aulas_historico', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'aula' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          if (partes[2] === 'apagar') {
            const r = await db.rpc('apagar_aula', { p: corpo });
            return jsonResponse(r, 200, ch);
          }
          const r = await db.rpc('salvar_aula', { p: { ...corpo, lancamento: slug } });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'vendas') {
          const r = await db.rpc('dash_vendas', { p: { lancamento: slug, produtos } });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'resumo-lancamento') {
          const de = url.searchParams.get('de') || '';
          const ate = url.searchParams.get('ate') || '';
          const prods = (url.searchParams.get('produtos') || '')
            .split('|').filter(Boolean);
          const r = await db.rpc('dash_resumo_lancamento', {
            p: { lancamento: slug, de, ate, produtos: prods },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'faturamento') {
          const prods = (url.searchParams.get('produtos') || '')
            .split('|').filter(Boolean);
          const r = await db.rpc('dash_faturamento', {
            p: {
              de: url.searchParams.get('de') || '',
              ate: url.searchParams.get('ate') || '',
              produtos: prods,
            },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'previa-apagar') {
          const r = await db.rpc('previa_apagar_lancamento', { p: { lancamento: slug } });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'apagar-lancamento' && req.method === 'POST') {
          const corpo = await req.json().catch(() => ({}));
          const r = await db.rpc('apagar_lancamento', {
            p: { lancamento: slug, confirmar: (corpo as any).confirmar || '' },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'escopo-lancamento' && req.method === 'POST') {
          const corpo = await req.json().catch(() => ({}));
          const r = await db.rpc('salvar_escopo_lancamento', {
            p: { ...(corpo as any), lancamento: slug },
          });
          return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
        }

        if (partes[1] === 'recorrencia') {
          const r = await db.rpc('dash_recorrencia', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'importacao' && req.method === 'GET') {
          const r = await db.rpc('resumo_importacao', { p: {} });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'ajustes' && req.method === 'GET') {
          const r = await db.rpc('dash_ajustes', { p: { lancamento: slug } });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'ajustes' && req.method === 'POST') {
          const corpo: any = await req.json().catch(() => ({}));
          const alvo = partes[2] || '';

          if (alvo === 'config') {
            const r = await db.rpc('salvar_config', { p: corpo });
            return jsonResponse(r, 200, ch);
          }
          if (alvo === 'custo') {
            const r = await db.rpc('salvar_custo', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'custo-apagar') {
            const r = await db.rpc('apagar_custo', { p: corpo });
            return jsonResponse(r, 200, ch);
          }
          if (alvo === 'plataforma') {
            const r = await db.rpc('salvar_plataforma', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'lancamento') {
            const r = await db.rpc('salvar_lancamento', {
              p: { ...corpo, lancamento: corpo.lancamento || slug },
            });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'importar-leads') {
            const r = await db.rpc('importar_leads', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'importar-vendas') {
            const r = await db.rpc('importar_vendas', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'gasto-manual') {
            const r = await db.rpc('lancar_gasto_manual', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'importar-captura') {
            const r = await db.rpc('importar_captura', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'importar-tags') {
            const r = await db.rpc('importar_tags_padrao', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'tags-do-lote') {
            const r = await db.rpc('tags_do_lote', { p: corpo });
            return jsonResponse(r, 200, ch);
          }
          if (alvo === 'desfazer-importacao') {
            const r = await db.rpc('desfazer_importacao', { p: corpo });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          if (alvo === 'zerar') {
            const r = await db.rpc('zerar_lancamento', {
              p: { ...corpo, lancamento: corpo.lancamento || slug },
            });
            return jsonResponse(r, r?.ok === false ? 400 : 200, ch);
          }
          return jsonResponse({ ok: false, erro: 'ajuste desconhecido' }, 400, ch);
        }

        if (partes[1] === 'produtos') {
          const r = await db.rpc('dash_produtos', {
            p: url.searchParams.get('todos') ? {} : { lancamento: slug },
          });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'reconciliar' && req.method === 'POST') {
          const r = await db.rpc('reconciliar_vendas', { p: { lancamento: slug } });
          return jsonResponse(r, 200, ch);
        }

        if (partes[1] === 'anuncios') {
          const r = await db.rpc('dash_anuncios', {
            p: {
              lancamento: slug,
              // o período escolhido na tela; vazio significa o
              // lançamento inteiro
              de: url.searchParams.get('de') || '',
              ate: url.searchParams.get('ate') || '',
            },
          });
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
        if (partes[1] === 'lead-respostas' && partes[2]) {
          const r = await db.rpc('respostas_do_lead', { p: { inscricao_id: partes[2] } });
          return jsonResponse(r, 200, ch);
        }

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

  // Cron de hora em hora: Meta Ads e reconciliação de vendas.
  async scheduled(_evento: ScheduledController, env: Env, ctx: ExecutionContext) {
    const db = new Supabase(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    ctx.waitUntil((async () => {
      try {
        const ativos = await db.select('lancamentos', {
          select: 'slug',
          status: 'in.(captacao,aquecimento,evento,carrinho)',
        });
        // ---- Instagram: duas vezes ao dia, 12h e 20h de Brasília
        //
        // O cron do Worker roda de hora em hora, então a escolha do
        // horário acontece aqui. Duas vezes basta: curtida e
        // salvamento entram devagar, e cada post custa uma chamada de
        // insights — sincronizar de hora em hora gastaria o limite da
        // API sem trazer número novo.
        //
        // 12h pega o desempenho do post da manhã; 20h fecha o dia
        // antes da aula, que é quando o cliente olha.
        try {
          const agora = new Date(
            new Date().toLocaleString('en-US', { timeZone: 'America/Sao_Paulo' }),
          );
          const hora = agora.getHours();

          if (hora === 12 || hora === 20) {
            const temConta = await db.select('ig_contas', {
              select: 'id', ativa: 'is.true', limit: '1',
            }).catch(() => null);

            if (temConta?.[0]?.id) {
              await igSincronizar({ quantos: 50 }, db, env).catch(() => {});
            }
          }
        } catch (_) { /* o resto do cron não pode parar por isso */ }

        // A fila de reativação primeiro: ela é a única coisa aqui com
        // alguém esperando do outro lado. Cinco voltas por execução
        // dão 200 leads por hora — uma base de 10 mil sai em dois dias
        // sem ninguém precisar deixar a tela aberta.
        for (let volta = 0; volta < 5; volta++) {
          const f = await processarFilaReativacao(db, env, 40).catch(() => null);
          if (!f || f.vazia || !f.pegos) break;
        }

        // o aviso de captação: a própria função decide se é hora,
        // respeitando o intervalo e o horário configurados
        try {
          await avisarCaptacao(db, env, false);
        } catch { /* aviso que falha não pode derrubar o resto do cron */ }

        // o investimento roda uma vez por hora, cobrindo os últimos 30
        // dias: campanha nova entra sozinha, sem ninguém apertar botão
        try {
          const inv = await sincronizarInvestimento(db, env, {
            de: new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10),
          });
          if (!inv.ok) {
            await db.insert('webhooks_raw', {
              fonte: 'sync_investimento_falhou', body: {},
              processado: false, erro: String(inv.erro).slice(0, 400),
            }).catch(() => {});
          }
        } catch (e: any) {
          await db.insert('webhooks_raw', {
            fonte: 'sync_investimento_falhou', body: {},
            processado: false, erro: String(e?.message || e).slice(0, 400),
          }).catch(() => {});
        }

        for (const l of ativos) {
          try {
            // venda pode chegar antes do lead existir; isso religa as pontas
            await db.rpc('reconciliar_vendas', { p: { lancamento: l.slug } }).catch(() => {});
            const r = await sincronizarMeta(l.slug, 7, db, env);
            if (!r.ok) {
              await db.insert('webhooks_raw', {
                fonte: 'sync_meta_falhou',
                body: { lancamento: l.slug, resposta: r },
                processado: false,
                erro: String(
                  r.erro
                  || (Array.isArray(r.erros) ? r.erros.join(' | ') : '')
                  || 'falhou sem mensagem — veja o corpo guardado',
                ).slice(0, 400),
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
