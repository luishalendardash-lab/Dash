/**
 * DASH DE LANÇAMENTO — API
 * Worker separado do de ingestão. Arquivo único, na raiz do repositório.
 *
 * Autenticação: o login passa por aqui. O front manda e-mail e senha, 
 * este Worker conversa com o Supabase Auth e devolve o token. Nenhuma
 * chave do Supabase existe no navegador — nem a anon.
 *
 * Rotas públicas:
 *   GET  /api/health
 *   POST /api/login     { email, senha } -> { token, refresh }
 *   POST /api/refresh   { refresh }      -> { token, refresh }
 *
 * Rotas com Authorization: Bearer <token>:
 *   GET /api/lancamentos
 *   GET /api/home?lancamento=slug&periodo=mes
 *   GET /api/leads?lancamento=slug&etapa=&busca=&pagina=0
 *   GET /api/lead/:id
 *   GET /api/health          (não exige token)
 */

interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  SUPABASE_ANON_KEY: string;
  ORIGENS_PERMITIDAS?: string;
}

// =====================================================================
// SUPABASE
// =====================================================================
class Supabase {
  constructor(private url: string, private key: string) {}

  private headers(schema = 'dash') {
    return {
      apikey: this.key,
      Authorization: `Bearer ${this.key}`,
      'Content-Type': 'application/json',
      'Accept-Profile': schema,
      'Content-Profile': schema,
    };
  }

  async rpc(fn: string, args: Record<string, any>): Promise<any> {
    const r = await fetch(`${this.url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        apikey: this.key,
        Authorization: `Bearer ${this.key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
    });
    const texto = await r.text();
    if (!r.ok) throw new Error(`rpc ${fn} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return texto; }
  }

  async select(tabela: string, filtros: Record<string, string> = {}, schema = 'dash') {
    const qs = new URLSearchParams(filtros).toString();
    const r = await fetch(`${this.url}/rest/v1/${tabela}?${qs}`, { headers: this.headers(schema) });
    const texto = await r.text();
    if (!r.ok) throw new Error(`select ${tabela} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return []; }
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

// =====================================================================
// HELPERS
// =====================================================================
function cors(origem: string | null, env: Env): Record<string, string> {
  const lista = (env.ORIGENS_PERMITIDAS || '').split(',').map((o) => o.trim()).filter(Boolean);
  const permitido = lista.length === 0 ? (origem || '*')
                  : (origem && lista.includes(origem) ? origem : '');
  if (!permitido) return {};
  return {
    'Access-Control-Allow-Origin': permitido,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
}

function json(dados: any, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(dados), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...extra },
  });
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
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const partes = url.pathname.split('/').filter(Boolean);
    const ch = cors(req.headers.get('origin'), env);
    const db = new Supabase(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: ch });
    if (partes[0] !== 'api') return json({ ok: false, erro: 'rota nao encontrada' }, 404, ch);

    try {
      if (partes[1] === 'health') {
        return json({
          ok: true,
          ts: new Date().toISOString(),
          config: {
            supabase_url: !!env.SUPABASE_URL,
            service_key: !!env.SUPABASE_SERVICE_KEY,
            anon_key: !!env.SUPABASE_ANON_KEY,
            origens: env.ORIGENS_PERMITIDAS || 'todas',
          },
        }, 200, ch);
      }

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
          return json({ ok: false, erro: 'e-mail ou senha incorretos' }, 401, ch);
        }
        return json({
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
          return json({ ok: false, erro: 'sessao expirada' }, 401, ch);
        }
        return json({
          ok: true, token: d.access_token, refresh: d.refresh_token,
          expira_em: d.expires_in || 3600,
        }, 200, ch);
      }

      const auth = req.headers.get('authorization') || '';
      const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
      const usuario = await usuarioDoToken(token, env);
      if (!usuario) return json({ ok: false, erro: 'nao autenticado' }, 401, ch);

      const slug = url.searchParams.get('lancamento') || '';

      // -------- lançamentos
      if (partes[1] === 'lancamentos') {
        const dados = await db.select('lancamentos', {
          select: 'id,slug,nome,status,captacao_inicio,carrinho_abre,carrinho_fecha,meta_leads,investimento_planejado',
          order: 'criado_em.desc',
        });
        return json({ ok: true, dados }, 200, ch);
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

        return json({ ok: true, usuario, receita, captura, serie }, 200, ch);
      }

      // -------- lista de leads
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
        return json({ ok: true, dados, pagina }, 200, ch);
      }

      // -------- ficha do lead
      if (partes[1] === 'lead' && partes[2]) {
        const id = partes[2];
        const ficha = await db.select('inscricoes', {
          select: '*,pessoas(nome,email,telefone,primeiro_contato)',
          id: `eq.${id}`, limit: '1',
        });
        if (!ficha[0]) return json({ ok: false, erro: 'lead nao encontrado' }, 404, ch);

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

        return json({ ok: true, lead: ficha[0], eventos, quiz }, 200, ch);
      }

      return json({ ok: false, erro: 'rota nao encontrada' }, 404, ch);
    } catch (e: any) {
      return json({ ok: false, erro: String(e?.message || e) }, 500, ch);
    }
  },
};
