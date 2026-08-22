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
  HOTMART_HOTTOK?: string;       // valida que o webhook veio mesmo da Hotmart
  TMB_TOKEN?: string;            // reserva; o normal é configurar pela tela
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

  if (cfgDireto?.ativa && cfgDireto?.valor) {
    try {
      const r = await enviarManychat(
        { nome: dados.nome, telefone: dados.telefone, lancamento: dados.lancamento },
        { token: cfgDireto.valor, ...(cfgDireto.config || {}) },
      );
      if (!r.ok) throw new Error(r.erro || 'falha no ManyChat');

      // tag que não aplicou não derruba o lead, mas fica registrada:
      // sem ela o fluxo do WhatsApp pode não disparar
      if (r.aviso_tag) {
        await db.insert('webhooks_raw', {
          fonte: 'manychat_tag_falhou',
          body: { subscriber_id: r.subscriber_id, aviso: r.aviso_tag },
          processado: true,
        }).catch(() => {});
      }
    } catch (e: any) {
      await db.insert('webhooks_raw', {
        fonte: 'saida_manychat_falhou',
        body: { dados, pessoa_id: pessoaId },
        processado: false,
        erro: String(e?.message || e).slice(0, 400),
      }).catch(() => {});
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
    const lp = lancamento || env.LANCAMENTO_PADRAO;
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
      case 'sendflow':
        resultado = await db.rpc('ingest_evento', { p: parseSendflow(body, lp, rawId) }); break;
      case 'manychat':
        resultado = await db.rpc('ingest_evento', { p: parseManychat(body, lp, rawId) }); break;
      case 'hotmart':
      case 'guru':
        resultado = await db.rpc('ingest_venda', { p: parseHotmart(body, lp, rawId) }); break;
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
function widgetJS(slug: string, base: string): string {
  return `(function(){
  var LANC = ${JSON.stringify(slug)};
  var API  = ${JSON.stringify(base)};
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
  var inscricaoId = null;
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

  telaForm();
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
          lancamento: env.LANCAMENTO_PADRAO,
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

  const contas: string[] = plano?.contas || [];
  if (!contas.length) {
    return { ok: false, erro: 'nenhuma conta de anuncio configurada em Ajustes' };
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
    // o token do ManyChat já vem no formato id:hash — o Bearer é nosso
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

  const r = await fetch(url, opcoes);
  const d: any = await r.json().catch(() => ({}));
  return { status: r.status, ...d };
}

/** Telefone no formato que o ManyChat aceita: +55 e só dígitos. */
function foneManychat(fone: string): string {
  const d = String(fone || '').replace(/\D/g, '');
  if (!d) return '';
  return d.startsWith('55') ? `+${d}` : `+55${d}`;
}

async function enviarManychat(lead: any, cfg: any): Promise<any> {
  const token = cfg?.token || '';
  if (!token) return { ok: false, erro: 'token do ManyChat nao configurado' };

  const fone = foneManychat(lead.telefone || lead.phone);
  if (!fone) return { ok: false, erro: 'lead sem telefone' };

  const nome = String(lead.nome || lead.name || '').trim();
  const partes = nome.split(/\s+/);
  const primeiro = partes[0] || 'Lead';
  const ultimo = partes.length > 1 ? partes.slice(1).join(' ') : '';

  // 1. tenta criar
  let id = '';
  const criado = await manychatChamar('/subscriber/createSubscriber', token, {
    first_name: primeiro,
    last_name: ultimo,
    phone: fone,
    whatsapp_phone: fone,
    has_opt_in_sms: true,
    consent_phrase: 'sim',
  });

  if (criado?.data?.id) {
    id = String(criado.data.id);
  } else {
    // 2. já existe: procura pelo telefone
    const achado = await manychatChamar(
      '/subscriber/findBySystemField', token, { phone: fone }, 'GET',
    );
    const lista = achado?.data;
    if (Array.isArray(lista) && lista[0]?.id) id = String(lista[0].id);
    else if (lista?.id) id = String(lista.id);

    if (!id) {
      return {
        ok: false,
        erro: criado?.details?.messages?.[0]?.message
          || criado?.message || 'nao consegui criar nem encontrar o contato',
      };
    }
  }

  // 3. tag, quando configurada
  const resultado: any = { ok: true, subscriber_id: id, criado: !!criado?.data?.id };

  if (cfg?.tag) {
    const tag = await manychatChamar('/subscriber/addTagByName', token, {
      subscriber_id: id,
      tag_name: cfg.tag,
    });
    resultado.tag_aplicada = tag?.status === 'success' || tag?.status === 200;
    if (!resultado.tag_aplicada) {
      resultado.aviso_tag = tag?.message || 'nao consegui aplicar a tag';
    }
  }

  // 4. campo com o lançamento, quando configurado: permite o fluxo do
  //    ManyChat se ramificar sem precisar de uma tag por lançamento
  if (cfg?.campo_lancamento && lead.lancamento) {
    await manychatChamar('/subscriber/setCustomFieldByName', token, {
      subscriber_id: id,
      field_name: cfg.campo_lancamento,
      field_value: lead.lancamento,
    });
  }

  return resultado;
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
            versao: 'v43-manychat-direto',
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

      // ============ WIDGET DA LP ============
      if (partes[0] === 'embed.js') {
        const slug = url.searchParams.get('l') || env.LANCAMENTO_PADRAO || '';
        return new Response(widgetJS(slug, url.origin), {
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
        const slug = url.searchParams.get('l') || env.LANCAMENTO_PADRAO;
        const lanc = await db.select('lancamentos',
          { select: 'id,slug,config', slug: `eq.${slug}`, limit: '1' });
        const destino = lanc?.[0]?.config?.grupo_url;
        if (!destino) return new Response('Grupo indisponível no momento.', { status: 404 });
        if (inscricaoId) {
          ctx.waitUntil(db.rpc('ingest_evento', {
            p: { inscricao_id: inscricaoId, tipo: 'grupo_click', fonte: 'interno',
                 lancamento: lanc[0].slug, payload: {} },
          }).catch(() => {}));
        }
        return Response.redirect(destino, 302);
      }

      // ============ QUIZ (público — o lead responde) ============
      if (partes[0] === 'quiz' && req.method === 'GET') {
        const slug = url.searchParams.get('l') || env.LANCAMENTO_PADRAO || '';
        const r = await db.rpc('quiz_publico', { p: { lancamento: slug } });
        return jsonResponse(r, r?.ok === false ? 404 : 200, ch);
      }

      if (partes[0] === 'quiz' && req.method === 'POST') {
        const corpo: any = await safeJson(req);

        // mesma proteção da captura: campo isca e tempo mínimo
        if (s(corpo?.empresa) || s(corpo?.website)) {
          return jsonResponse({ ok: true, recebido: true }, 200, ch);
        }

        const r = await db.rpc('responder_quiz', {
          p: {
            inscricao_id: s(corpo?.inscricao_id),
            email: s(corpo?.email),
            telefone: s(corpo?.telefone),
            lancamento: s(corpo?.lancamento) || env.LANCAMENTO_PADRAO,
            respostas: corpo?.respostas || {},
          },
        });
        if (r?.ok === false) return jsonResponse(r, 400, ch);

        // devolve o link do grupo já rastreado
        const slug = s(corpo?.lancamento) || env.LANCAMENTO_PADRAO || '';
        const link = `${url.origin}/r/grupo/publico`
                   + `?l=${encodeURIComponent(slug)}&i=${r.inscricao_id}`;
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
          const r = await db.rpc('salvar_quiz', { p: corpo });
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
        for (const l of ativos) {
          try {
            // venda pode chegar antes do lead existir; isso religa as pontas
            await db.rpc('reconciliar_vendas', { p: { lancamento: l.slug } }).catch(() => {});
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
