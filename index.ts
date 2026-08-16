/**
 * DASH DE LANÇAMENTO — WORKER DE INGESTÃO (arquivo único)
 *
 * Vai na RAIZ do repositório, ao lado do wrangler.jsonc. Sem pastas.
 *
 * Rotas:
 *   POST /w/:fonte/:secret   webhook (sellflux, quiz, sendflow, manychat, hotmart, teste)
 *   GET  /r/grupo/:secret    redirect rastreado para o grupo de WhatsApp
 *   GET  /debug/ultimos      últimos payloads crus
 *   POST /debug/reprocessar  reprocessa o que falhou
 *   GET  /health
 */

interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  WEBHOOK_SECRET: string;
  DEBUG_TOKEN: string;
  LANCAMENTO_PADRAO?: string;
}

const FONTES_VALIDAS = ['sellflux', 'quiz', 'sendflow', 'manychat', 'hotmart', 'teste'];

// =====================================================================
// CLIENTE SUPABASE (PostgREST via fetch — sem dependência)
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
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(args),
    });
    const texto = await r.text();
    if (!r.ok) throw new Error(`rpc ${fn} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return texto; }
  }

  async insert(tabela: string, dados: any, schema = 'public'): Promise<any> {
    const r = await fetch(`${this.url}/rest/v1/${tabela}`, {
      method: 'POST',
      headers: this.headers(schema, { Prefer: 'return=representation' }),
      body: JSON.stringify(dados),
    });
    const texto = await r.text();
    if (!r.ok) throw new Error(`insert ${tabela} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return null; }
  }

  async update(tabela: string, filtros: Record<string, string>, dados: any, schema = 'public') {
    const qs = new URLSearchParams(filtros).toString();
    const r = await fetch(`${this.url}/rest/v1/${tabela}?${qs}`, {
      method: 'PATCH',
      headers: this.headers(schema, { Prefer: 'return=minimal' }),
      body: JSON.stringify(dados),
    });
    if (!r.ok) throw new Error(`update ${tabela} ${r.status}`);
    return true;
  }

  async select(tabela: string, filtros: Record<string, string> = {}, schema = 'public'): Promise<any[]> {
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
function jsonResponse(dados: any, status = 200): Response {
  return new Response(JSON.stringify(dados, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

/** Lê o corpo em JSON, form-urlencoded ou texto solto. */
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
// Em vez de mapear campo a campo, a gente CAÇA o dado em qualquer
// profundidade do objeto, aceitando variações de nome.
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

/** Extrai UTMs de campos soltos E de qualquer URL presente no payload. */
function extrairUtm(body: any) {
  const utm: any = {
    source: s(achar(body, ['utm_source', 'utmsource', 'source', 'origem_utm'])),
    medium: s(achar(body, ['utm_medium', 'utmmedium', 'medium'])),
    campaign: s(achar(body, ['utm_campaign', 'utmcampaign', 'campaign', 'campanha'])),
    content: s(achar(body, ['utm_content', 'utmcontent', 'content', 'criativo'])),
    term: s(achar(body, ['utm_term', 'utmterm', 'term'])),
  };
  const meta: any = {
    campaign_id: s(achar(body, ['cid', 'campaign_id', 'campaignid', 'utm_campaign_id'])),
    adset_id: s(achar(body, ['aid', 'adset_id', 'adsetid', 'conjunto_id'])),
    ad_id: s(achar(body, ['adid', 'ad_id', 'anuncio_id', 'creative_id'])),
  };
  let fbclid = s(achar(body, ['fbclid', 'fbc']));
  const landing = s(achar(body, ['url', 'page_url', 'landing_url', 'pagina', 'link', 'referer_url']));

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
    } catch { /* URL torta, ignora */ }
  }
  return { utm, meta, fbclid, landing_url: landing };
}

function parseSellflux(body: any, lancamentoPadrao?: string, rawId?: number | null) {
  const { utm, meta, fbclid, landing_url } = extrairUtm(body);
  const idOrigem = s(achar(body, ['id', 'lead_id', 'leadid', 'uuid', 'contact_id']));
  return {
    lancamento: s(achar(body, ['lancamento', 'launch', 'lanc'])) || lancamentoPadrao,
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    origem: 'sellflux',
    sellflux_lead_id: idOrigem,
    capturado_em: s(achar(body, ['created_at', 'data', 'date', 'timestamp', 'capturado_em'])),
    utm, meta, fbclid, landing_url,
    dedupe_key: idOrigem ? `sellflux:${idOrigem}` : rawId ? `raw:${rawId}` : undefined,
    payload: body,
  };
}

function parseQuiz(body: any, lancamentoPadrao?: string, rawId?: number | null) {
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
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lancamentoPadrao,
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

function parseSendflow(body: any, lancamentoPadrao?: string, rawId?: number | null) {
  const evento = (s(achar(body, ['event', 'evento', 'tipo', 'action', 'status'])) || '').toLowerCase();
  let tipo = 'grupo_entrou';
  if (/(sai|left|remov|exit|out)/.test(evento)) tipo = 'grupo_saiu';
  else if (/(entr|join|add|in)/.test(evento)) tipo = 'grupo_entrou';

  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lancamentoPadrao,
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    tipo,
    fonte: 'sendflow',
    ocorreu_em: s(achar(body, ['created_at', 'timestamp', 'data', 'date'])),
    payload: {
      grupo: s(achar(body, ['grupo', 'group', 'group_name', 'nome_grupo'])),
      evento_original: evento,
      raw: body,
    },
    dedupe_key: rawId ? `sendflow:raw:${rawId}` : undefined,
  };
}

function parseManychat(body: any, lancamentoPadrao?: string, rawId?: number | null) {
  const evento = (s(achar(body, ['event', 'evento', 'type', 'tipo'])) || '').toLowerCase();
  const tipo = /(reply|resposta|received|inbound|respondeu)/.test(evento)
    ? 'whats_respondido' : 'whats_enviado';
  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lancamentoPadrao,
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    nome: s(achar(body, NOME_KEYS)),
    tipo,
    fonte: 'manychat',
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

function parseHotmart(body: any, lancamentoPadrao?: string, rawId?: number | null) {
  const bruto = (s(achar(body, ['status', 'event', 'evento', 'transaction_status'])) || '').toLowerCase();
  const valor = Number(achar(body, ['full_price', 'price', 'valor', 'total', 'amount', 'purchase_value']) ?? 0) || 0;
  const metodoBruto = (s(achar(body, ['payment_type', 'metodo', 'payment_method'])) || '').toLowerCase();
  const metodo = /pix/.test(metodoBruto) ? 'pix'
               : /(billet|boleto)/.test(metodoBruto) ? 'boleto'
               : /(credit|card|cartao)/.test(metodoBruto) ? 'cartao'
               : metodoBruto || undefined;

  return {
    lancamento: s(achar(body, ['lancamento', 'launch'])) || lancamentoPadrao,
    plataforma: 'hotmart',
    transacao_id: s(achar(body, ['transaction', 'transaction_id', 'transacao', 'order_id']))
                  || (rawId ? `raw-${rawId}` : `sem-id-${Date.now()}`),
    produto: s(achar(body, ['product_name', 'prod_name', 'produto', 'name'])),
    oferta: s(achar(body, ['offer', 'oferta', 'off', 'offer_code'])),
    status: STATUS_HOTMART[bruto] || 'pendente',
    metodo,
    parcelas: s(achar(body, ['installments_number', 'parcelas', 'installments'])),
    valor_bruto: valor,
    valor_liquido: Number(achar(body, ['producer_value', 'commission', 'valor_liquido']) ?? 0) || 0,
    moeda: s(achar(body, ['currency', 'currency_code', 'moeda'])) || 'BRL',
    email: s(achar(body, EMAIL_KEYS)),
    telefone: s(achar(body, FONE_KEYS)),
    src: s(achar(body, ['src', 'sck', 'source'])),
    ocorreu_em: s(achar(body, ['purchase_date', 'order_date', 'creation_date', 'timestamp'])),
    raw: body,
  };
}

// =====================================================================
// PROCESSAMENTO
// =====================================================================
async function processar(
  fonte: string, body: any, rawId: number | null, db: Supabase, env: Env
): Promise<void> {
  try {
    let resultado: any;
    const lp = env.LANCAMENTO_PADRAO;

    switch (fonte) {
      case 'sellflux':
      case 'teste':
        resultado = await db.rpc('ingest_lead', { p: parseSellflux(body, lp, rawId) });
        break;
      case 'quiz':
        resultado = await db.rpc('ingest_quiz', { p: parseQuiz(body, lp, rawId) });
        break;
      case 'sendflow':
        resultado = await db.rpc('ingest_evento', { p: parseSendflow(body, lp, rawId) });
        break;
      case 'manychat':
        resultado = await db.rpc('ingest_evento', { p: parseManychat(body, lp, rawId) });
        break;
      case 'hotmart':
        resultado = await db.rpc('ingest_venda', { p: parseHotmart(body, lp, rawId) });
        break;
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
        processado: false,
        erro: String(e?.message || e).slice(0, 500),
      }, 'dash').catch(() => {});
    }
  }
}

// =====================================================================
// ROTEADOR
// =====================================================================
export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const partes = url.pathname.split('/').filter(Boolean);
    const db = new Supabase(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    try {
      if (partes[0] === 'health') {
        return jsonResponse({
          ok: true,
          ts: new Date().toISOString(),
          config: {
            supabase_url: !!env.SUPABASE_URL,
            supabase_key: !!env.SUPABASE_SERVICE_KEY,
            webhook_secret: env.WEBHOOK_SECRET ? `${env.WEBHOOK_SECRET.length} chars` : false,
            debug_token: !!env.DEBUG_TOKEN,
            lancamento_padrao: env.LANCAMENTO_PADRAO || false,
          },
        });
      }

      // WEBHOOK
      if (partes[0] === 'w' && req.method === 'POST') {
        const fonte = (partes[1] || '').toLowerCase();
        const secret = partes[2] || url.searchParams.get('k') || '';

        if (secret !== env.WEBHOOK_SECRET) return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401);
        if (!FONTES_VALIDAS.includes(fonte)) return jsonResponse({ ok: false, erro: 'fonte desconhecida' }, 400);

        const body = await safeJson(req);
        const headers: Record<string, string> = {};
        req.headers.forEach((v, k) => { headers[k] = v; });

        const raw = await db.insert('webhooks_raw', { fonte, headers, body, processado: false }, 'dash');
        const rawId = raw?.[0]?.id ?? null;

        // responde na hora; processa depois
        ctx.waitUntil(processar(fonte, body, rawId, db, env));
        return jsonResponse({ ok: true, recebido: true, raw_id: rawId });
      }

      // REDIRECT RASTREADO PRO GRUPO
      // destino vem do banco, nunca da querystring (evita open redirect)
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
              inscricao_id: inscricaoId,
              tipo: 'grupo_click',
              fonte: 'interno',
              lancamento: lanc[0].slug,
              payload: { ua: req.headers.get('user-agent') || '' },
            },
          }).catch(() => {}));
        }
        return Response.redirect(destino, 302);
      }

      // DEBUG: ver payloads crus
      if (partes[0] === 'debug' && partes[1] === 'ultimos') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401);
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

      // DEBUG: reprocessar falhas
      if (partes[0] === 'debug' && partes[1] === 'reprocessar' && req.method === 'POST') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401);
        }
        const pendentes = await db.select('webhooks_raw',
          { select: 'id,fonte,body', processado: 'eq.false', order: 'recebido_em.asc', limit: '100' }, 'dash');

        let ok = 0, falhou = 0;
        for (const p of pendentes) {
          try { await processar(p.fonte, p.body, p.id, db, env); ok++; } catch { falhou++; }
        }
        return jsonResponse({ ok: true, reprocessados: ok, falharam: falhou });
      }

      return jsonResponse({ ok: false, erro: 'rota nao encontrada' }, 404);
    } catch (e: any) {
      return jsonResponse({ ok: false, erro: String(e?.message || e) }, 500);
    }
  },
};
