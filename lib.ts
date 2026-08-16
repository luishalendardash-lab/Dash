/**
 * Cliente Supabase via PostgREST — fetch puro, sem dependência.
 * Driver de Postgres não roda bem no Worker; HTTP roda nativo.
 */

export class Supabase {
  constructor(private url: string, private key: string) {}

  private headers(schema?: string, extra: Record<string, string> = {}) {
    const h: Record<string, string> = {
      apikey: this.key,
      Authorization: `Bearer ${this.key}`,
      'Content-Type': 'application/json',
      ...extra,
    };
    // acessa tabelas de outro schema sem expor ele publicamente
    if (schema && schema !== 'public') {
      h['Accept-Profile'] = schema;
      h['Content-Profile'] = schema;
    }
    return h;
  }

  /** Chama uma função RPC (as funções de ingestão ficam em public). */
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

  async update(
    tabela: string,
    filtros: Record<string, string>,
    dados: any,
    schema = 'public'
  ): Promise<any> {
    const qs = new URLSearchParams(filtros).toString();
    const r = await fetch(`${this.url}/rest/v1/${tabela}?${qs}`, {
      method: 'PATCH',
      headers: this.headers(schema, { Prefer: 'return=minimal' }),
      body: JSON.stringify(dados),
    });
    if (!r.ok) throw new Error(`update ${tabela} ${r.status}`);
    return true;
  }

  async select(
    tabela: string,
    filtros: Record<string, string> = {},
    schema = 'public'
  ): Promise<any[]> {
    const qs = new URLSearchParams(filtros).toString();
    const r = await fetch(`${this.url}/rest/v1/${tabela}?${qs}`, {
      headers: this.headers(schema),
    });
    const texto = await r.text();
    if (!r.ok) throw new Error(`select ${tabela} ${r.status}: ${texto.slice(0, 300)}`);
    try { return JSON.parse(texto); } catch { return []; }
  }
}

export function jsonResponse(dados: any, status = 200): Response {
  return new Response(JSON.stringify(dados, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

/**
 * Lê o corpo do webhook em qualquer formato. SellFlux, ManyChat e cia
 * mandam JSON, form-urlencoded ou multipart dependendo da configuração.
 */
export async function safeJson(req: Request): Promise<any> {
  const tipo = (req.headers.get('content-type') || '').toLowerCase();
  const texto = await req.text();
  if (!texto) return {};

  if (tipo.includes('application/json')) {
    try { return JSON.parse(texto); } catch { return { _texto_bruto: texto }; }
  }

  if (tipo.includes('form-urlencoded')) {
    const obj: Record<string, any> = {};
    new URLSearchParams(texto).forEach((v, k) => {
      // alguns enviam um campo "payload" com JSON dentro
      try { obj[k] = JSON.parse(v); } catch { obj[k] = v; }
    });
    return obj;
  }

  try { return JSON.parse(texto); } catch { return { _texto_bruto: texto }; }
}
