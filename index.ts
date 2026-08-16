/**
 * DASH DE LANÇAMENTO — WORKER DE INGESTÃO
 *
 * Rotas:
 *   POST /w/:fonte/:secret     recebe webhook (sellflux, quiz, sendflow, manychat, hotmart)
 *   GET  /r/grupo/:secret      redirect rastreado para o grupo de WhatsApp
 *   GET  /debug/ultimos        últimos payloads crus (para descobrir o formato real)
 *   POST /debug/reprocessar    reprocessa payloads crus que falharam
 *   GET  /health
 *
 * Princípio: NUNCA devolve erro para o webhook. Grava o cru primeiro,
 * responde 200, e só então tenta interpretar. Se o parser errar, o dado
 * continua no banco e você reprocessa depois.
 */

import { Supabase, jsonResponse, safeJson } from './lib';
import { parseSellflux, parseQuiz, parseSendflow, parseManychat, parseHotmart } from './parsers';

export interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  WEBHOOK_SECRET: string;
  DEBUG_TOKEN: string;
  LANCAMENTO_PADRAO?: string;
}

const FONTES_VALIDAS = ['sellflux', 'quiz', 'sendflow', 'manychat', 'hotmart', 'teste'];

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const partes = url.pathname.split('/').filter(Boolean);
    const db = new Supabase(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    try {
      if (partes[0] === 'health') {
        return jsonResponse({ ok: true, ts: new Date().toISOString() });
      }

      // ---------------------------------------------------------------
      // WEBHOOK:  POST /w/:fonte/:secret
      // ---------------------------------------------------------------
      if (partes[0] === 'w' && req.method === 'POST') {
        const fonte = (partes[1] || '').toLowerCase();
        const secret = partes[2] || url.searchParams.get('k') || '';

        if (secret !== env.WEBHOOK_SECRET) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401);
        }
        if (!FONTES_VALIDAS.includes(fonte)) {
          return jsonResponse({ ok: false, erro: 'fonte desconhecida' }, 400);
        }

        const body = await safeJson(req);
        const headers: Record<string, string> = {};
        req.headers.forEach((v, k) => { headers[k] = v; });

        // 1) grava o cru SEMPRE, antes de qualquer interpretação
        const raw = await db.insert('webhooks_raw', {
          fonte,
          headers,
          body,
          processado: false,
        }, 'dash');

        const rawId = raw?.[0]?.id ?? null;

        // 2) responde na hora — webhook não pode esperar processamento
        ctx.waitUntil(processar(fonte, body, rawId, db, env));

        return jsonResponse({ ok: true, recebido: true, raw_id: rawId });
      }

      // ---------------------------------------------------------------
      // REDIRECT RASTREADO PARA O GRUPO
      //   /r/grupo/:secret?i=<inscricao_id>&l=<slug_lancamento>
      // O destino vem do banco (lancamentos.config->>'grupo_url'), nunca
      // da querystring — senão vira open redirect e o link é usado como
      // ponte para phishing em cima da reputação do domínio do cliente.
      // ---------------------------------------------------------------
      if (partes[0] === 'r' && partes[1] === 'grupo') {
        const secret = partes[2] || '';
        if (secret !== env.WEBHOOK_SECRET) {
          return new Response('Link inválido.', { status: 403 });
        }

        const inscricaoId = url.searchParams.get('i');
        const slug = url.searchParams.get('l') || env.LANCAMENTO_PADRAO;

        const lanc = await db.select('lancamentos', {
          select: 'id,slug,config',
          slug: `eq.${slug}`,
          limit: '1',
        }, 'dash');

        const destino = lanc?.[0]?.config?.grupo_url;
        if (!destino) {
          return new Response('Grupo indisponível no momento.', { status: 404 });
        }

        if (inscricaoId) {
          ctx.waitUntil(
            db.rpc('ingest_evento', {
              p: {
                inscricao_id: inscricaoId,
                tipo: 'grupo_click',
                fonte: 'interno',
                lancamento: lanc[0].slug,
                payload: { ua: req.headers.get('user-agent') || '' },
              },
            }).catch(() => {})
          );
        }

        return Response.redirect(destino, 302);
      }

      // ---------------------------------------------------------------
      // DEBUG: ver os últimos payloads crus (é assim que você descobre
      // o formato real de cada ferramenta sem ler documentação ruim)
      // ---------------------------------------------------------------
      if (partes[0] === 'debug' && partes[1] === 'ultimos') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401);
        }
        const fonte = url.searchParams.get('fonte');
        const filtros: Record<string, string> = {
          select: 'id,fonte,recebido_em,processado,erro,body',
          order: 'recebido_em.desc',
          limit: url.searchParams.get('n') || '5',
        };
        if (fonte) filtros.fonte = `eq.${fonte}`;
        const dados = await db.select('webhooks_raw', filtros, 'dash');
        return jsonResponse({ ok: true, total: dados.length, dados });
      }

      // ---------------------------------------------------------------
      // DEBUG: reprocessar o que falhou (depois de corrigir o parser)
      // ---------------------------------------------------------------
      if (partes[0] === 'debug' && partes[1] === 'reprocessar' && req.method === 'POST') {
        if (url.searchParams.get('token') !== env.DEBUG_TOKEN) {
          return jsonResponse({ ok: false, erro: 'nao autorizado' }, 401);
        }
        const pendentes = await db.select('webhooks_raw', {
          select: 'id,fonte,body',
          processado: 'eq.false',
          order: 'recebido_em.asc',
          limit: '100',
        }, 'dash');

        let ok = 0, falhou = 0;
        for (const p of pendentes) {
          try {
            await processar(p.fonte, p.body, p.id, db, env);
            ok++;
          } catch {
            falhou++;
          }
        }
        return jsonResponse({ ok: true, reprocessados: ok, falharam: falhou });
      }

      return jsonResponse({ ok: false, erro: 'rota nao encontrada' }, 404);

    } catch (e: any) {
      return jsonResponse({ ok: false, erro: String(e?.message || e) }, 500);
    }
  },
};

// =====================================================================
// PROCESSAMENTO
// =====================================================================
async function processar(
  fonte: string,
  body: any,
  rawId: number | null,
  db: Supabase,
  env: Env
): Promise<void> {
  try {
    let resultado: any;

    switch (fonte) {
      case 'sellflux':
      case 'teste': {
        const p = parseSellflux(body, env.LANCAMENTO_PADRAO, rawId);
        resultado = await db.rpc('ingest_lead', { p });
        break;
      }
      case 'quiz': {
        const p = parseQuiz(body, env.LANCAMENTO_PADRAO, rawId);
        resultado = await db.rpc('ingest_quiz', { p });
        break;
      }
      case 'sendflow': {
        const p = parseSendflow(body, env.LANCAMENTO_PADRAO, rawId);
        resultado = await db.rpc('ingest_evento', { p });
        break;
      }
      case 'manychat': {
        const p = parseManychat(body, env.LANCAMENTO_PADRAO, rawId);
        resultado = await db.rpc('ingest_evento', { p });
        break;
      }
      case 'hotmart': {
        const p = parseHotmart(body, env.LANCAMENTO_PADRAO, rawId);
        resultado = await db.rpc('ingest_venda', { p });
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
        processado: false,
        erro: String(e?.message || e).slice(0, 500),
      }, 'dash').catch(() => {});
    }
  }
}
