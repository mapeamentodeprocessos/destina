// Destina · função "assistente" (Supabase Edge Function)
// Intermediário seguro entre o navegador e o modelo de IA: a chave fica só no servidor.
// O navegador envia {system, messages, tools} no formato da API da Anthropic; as ferramentas
// (consultas ao estoque, planos, empenhos...) são executadas no navegador, com os dados que o
// usuário já pode ver. Só usuários com acesso aprovado no Destina podem usar.
//
// Segredos (Edge Functions › Secrets) — cadastre UM dos dois:
//   ANTHROPIC_API_KEY   (modelo: ANTHROPIC_MODEL, padrão claude-sonnet-5-5)
//   GEMINI_API_KEY      (modelo: GEMINI_MODEL, padrão gemini-2.5-flash)
// SUPABASE_URL e SUPABASE_ANON_KEY já existem em toda função do Supabase.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// limite simples por usuário (por instância da função)
const uso = new Map<string, number[]>();
function permitido(uid: string, porMinuto = 40) {
  const agora = Date.now(); const t = (uso.get(uid) || []).filter((x) => agora - x < 60000);
  if (t.length >= porMinuto) return false; t.push(agora); uso.set(uid, t); return true;
}

async function usuarioAprovado(token: string): Promise<string | null> {
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const u = await fetch(url + "/auth/v1/user", { headers: { apikey: anon, Authorization: "Bearer " + token } });
  if (!u.ok) return null;
  const user = await u.json(); if (!user?.id) return null;
  const p = await fetch(url + "/rest/v1/perfis?select=aprovado&id=eq." + user.id, { headers: { apikey: anon, Authorization: "Bearer " + token } });
  if (!p.ok) return null;
  const rows = await p.json();
  return rows?.[0]?.aprovado ? user.id : null;
}

// ---------- Anthropic ----------
async function anthropic(body: any) {
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": Deno.env.get("ANTHROPIC_API_KEY")!, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5",
      max_tokens: 1600, system: body.system, messages: body.messages, tools: body.tools?.length ? body.tools : undefined,
    }),
  });
  const j = await r.json();
  if (!r.ok) throw Object.assign(new Error(j?.error?.message || "Falha no modelo de IA"), { status: r.status });
  return { content: j.content, stop_reason: j.stop_reason };
}

// ---------- Google Gemini (convertido para o mesmo formato) ----------
function limparSchema(s: any): any {
  if (Array.isArray(s)) return s.map(limparSchema);
  if (!s || typeof s !== "object") return s;
  const o: any = {};
  for (const [k, v] of Object.entries(s)) { if (["additionalProperties", "$schema", "default", "examples"].includes(k)) continue; o[k] = limparSchema(v); }
  return o;
}
async function gemini(body: any) {
  const nomes: Record<string, string> = {};
  const contents = (body.messages || []).map((m: any) => {
    const parts: any[] = [];
    const blocos = typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content || [];
    for (const b of blocos) {
      if (b.type === "text" && b.text) parts.push({ text: b.text });
      else if (b.type === "tool_use") { nomes[b.id] = b.name; parts.push({ functionCall: { name: b.name, args: b.input || {} } }); }
      else if (b.type === "tool_result") {
        let resp: any = b.content; try { resp = JSON.parse(b.content); } catch (_) { /* texto */ }
        parts.push({ functionResponse: { name: nomes[b.tool_use_id] || "ferramenta", response: { resultado: resp } } });
      }
    }
    return { role: m.role === "assistant" ? "model" : "user", parts: parts.length ? parts : [{ text: " " }] };
  });
  const model = Deno.env.get("GEMINI_MODEL") || "gemini-2.5-flash";
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${Deno.env.get("GEMINI_API_KEY")}`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: body.system || "" }] }, contents,
      tools: body.tools?.length ? [{ functionDeclarations: body.tools.map((t: any) => ({ name: t.name, description: t.description, parameters: limparSchema(t.input_schema) })) }] : undefined,
      generationConfig: { maxOutputTokens: 1600, temperature: 0.2 },
    }),
  });
  const j = await r.json();
  if (!r.ok) throw Object.assign(new Error(j?.error?.message || "Falha no modelo de IA"), { status: r.status });
  const parts = j?.candidates?.[0]?.content?.parts || [];
  const content: any[] = []; let usaFerramenta = false;
  parts.forEach((p: any, i: number) => {
    if (p.text) content.push({ type: "text", text: p.text });
    if (p.functionCall) { usaFerramenta = true; content.push({ type: "tool_use", id: "g" + Date.now().toString(36) + i, name: p.functionCall.name, input: p.functionCall.args || {} }); }
  });
  if (!content.length) content.push({ type: "text", text: "Não consegui formular uma resposta agora. Tente reformular a pergunta." });
  return { content, stop_reason: usaFerramenta ? "tool_use" : "end_turn" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "Método não permitido." }, 405);
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ erro: "Entre no Destina para usar o assistente." }, 401);
  const uid = await usuarioAprovado(token);
  if (!uid) return json({ erro: "Seu acesso ao Destina ainda não foi aprovado." }, 403);
  if (!permitido(uid)) return json({ erro: "Muitas perguntas seguidas. Aguarde um minuto." }, 429);
  const temAnthropic = !!Deno.env.get("ANTHROPIC_API_KEY"), temGemini = !!Deno.env.get("GEMINI_API_KEY");
  if (!temAnthropic && !temGemini) return json({ erro: "O assistente de IA ainda não foi configurado (falta a chave do modelo).", codigo: "sem_chave" }, 503);
  let body: any; try { body = await req.json(); } catch (_) { return json({ erro: "Requisição inválida." }, 400); }
  if (!Array.isArray(body?.messages) || body.messages.length > 60) return json({ erro: "Conversa inválida ou longa demais." }, 400);
  try {
    const out = temAnthropic ? await anthropic(body) : await gemini(body);
    return json(out);
  } catch (e) {
    const st = (e as any).status === 429 ? 429 : 502;
    return json({ erro: st === 429 ? "O serviço de IA está ocupado. Tente em instantes." : "O serviço de IA não respondeu: " + (e as Error).message }, st);
  }
});
