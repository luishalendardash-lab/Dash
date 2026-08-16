/**
 * PARSERS TOLERANTES
 *
 * Nenhuma dessas ferramentas garante formato estável de payload. Em vez
 * de mapear campo a campo, aqui a gente CAÇA o dado: procura a chave em
 * qualquer profundidade do objeto, aceitando variações de nome.
 * Se mudar o payload amanhã, na maioria dos casos continua funcionando.
 */

// ---------------------------------------------------------------------
// BUSCA PROFUNDA
// ---------------------------------------------------------------------

/** Procura, em qualquer nível, a primeira chave que bata com os nomes dados. */
export function achar(obj: any, nomes: string[], profundidade = 6): any {
  if (!obj || typeof obj !== 'object' || profundidade < 0) return undefined;
  const alvos = nomes.map((n) => n.toLowerCase().replace(/[^a-z0-9]/g, ''));

  for (const [k, v] of Object.entries(obj)) {
    const chave = k.toLowerCase().replace(/[^a-z0-9]/g, '');
    if (alvos.includes(chave) && v !== null && v !== '' && typeof v !== 'object') {
      return v;
    }
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

// ---------------------------------------------------------------------
// UTM
// ---------------------------------------------------------------------

/** Extrai UTMs de campos soltos E de qualquer URL que apareça no payload. */
export function extrairUtm(body: any): { utm: any; meta: any; fbclid?: string; landing_url?: string } {
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

  // se veio uma URL completa, ela é a fonte mais confiável de todas
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

const EMAIL_KEYS = ['email', 'e_mail', 'mail', 'lead_email', 'buyer_email', 'contact_email'];
const FONE_KEYS = ['telefone', 'phone', 'whatsapp', 'celular', 'fone', 'phone_number',
                   'mobile', 'lead_phone', 'buyer_phone', 'wa_id', 'numero'];
const NOME_KEYS = ['nome', 'name', 'full_name', 'first_name', 'lead_name', 'buyer_name', 'nome_completo'];

// ---------------------------------------------------------------------
// SELLFLUX — captura de lead
// ---------------------------------------------------------------------
export function parseSellflux(body: any, lancamentoPadrao?: string, rawId?: number | null) {
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
    utm,
    meta,
    fbclid,
    landing_url,
    dedupe_key: idOrigem ? `sellflux:${idOrigem}` : rawId ? `raw:${rawId}` : undefined,
    payload: body,
  };
}

// ---------------------------------------------------------------------
// QUIZ
// ---------------------------------------------------------------------
export function parseQuiz(body: any, lancamentoPadrao?: string, rawId?: number | null) {
  let respostas = achar(body, ['respostas', 'answers', 'resultados']);
  if (!Array.isArray(respostas)) {
    respostas = Array.isArray(body?.respostas) ? body.respostas
              : Array.isArray(body?.answers) ? body.answers
              : [];
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

// ---------------------------------------------------------------------
// SENDFLOW — entrada/saída de grupo
// ---------------------------------------------------------------------
export function parseSendflow(body: any, lancamentoPadrao?: string, rawId?: number | null) {
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

// ---------------------------------------------------------------------
// MANYCHAT — mensagem WhatsApp
// ---------------------------------------------------------------------
export function parseManychat(body: any, lancamentoPadrao?: string, rawId?: number | null) {
  const evento = (s(achar(body, ['event', 'evento', 'type', 'tipo'])) || '').toLowerCase();
  const tipo = /(reply|resposta|received|inbound|respondeu)/.test(evento)
    ? 'whats_respondido'
    : 'whats_enviado';

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

// ---------------------------------------------------------------------
// HOTMART — venda
// ---------------------------------------------------------------------
const STATUS_HOTMART: Record<string, string> = {
  approved: 'aprovada',
  complete: 'aprovada',
  purchase_approved: 'aprovada',
  purchase_complete: 'aprovada',
  waiting_payment: 'pendente',
  purchase_billet_printed: 'pendente',
  printed_billet: 'pendente',
  purchase_protest: 'pendente',
  canceled: 'cancelada',
  purchase_canceled: 'cancelada',
  expired: 'cancelada',
  refunded: 'reembolsada',
  purchase_refunded: 'reembolsada',
  chargeback: 'chargeback',
  purchase_chargeback: 'chargeback',
};

export function parseHotmart(body: any, lancamentoPadrao?: string, rawId?: number | null) {
  const bruto = (s(achar(body, ['status', 'event', 'evento', 'transaction_status'])) || '')
    .toLowerCase();

  const valor = Number(
    achar(body, ['full_price', 'price', 'valor', 'total', 'amount', 'purchase_value']) ?? 0
  ) || 0;

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
