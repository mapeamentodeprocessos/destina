"""Bateria de conversas do assistente do Destina.

Uso:  python3 tests/rodar_chat.py            (testa o index.html local, no modo demonstração)
      python3 tests/rodar_chat.py --url https://...   (testa o site publicado)
Requer: pip install playwright  (e um Chrome/Chromium)
Sai com código 1 se algum caso falhar, para o GitHub Actions bloquear a mudança.
"""
import asyncio, json, os, re, sys, shutil
from playwright.async_api import async_playwright

AQUI = os.path.dirname(os.path.abspath(__file__))
CASOS = json.load(open(os.path.join(AQUI, "chat-casos.json"), encoding="utf-8"))["casos"]
GERAL_PROIBIDO = ["undefined", "NaN", "[object", "ERRO:", "null", "&quot;", "&amp;", "&lt;", "&#39;"]

JS = """async (caso) => {
  localStorage.removeItem(DEMO_KEY);
  await seedDemo();
  await enterDemoPersona(caso.persona, true);
  AS.slot = null; AS.ctx = null; AS.msgs = [];
  const out = [];
  for (const m of caso.msgs) {
    const msg = {actions: [], sug: null}; let r;
    try { r = String(await localAnswer(m.q, msg)); } catch (e) { r = "ERRO: " + e.message; }
    const d = document.createElement("div"); d.innerHTML = mdLite(r);
    out.push({r: d.innerText.replace(/\u00a0/g, " ").trim(), bruto: r, botoes: msg.actions.map(a => a.rotulo), sug: msg.sug || []});
  }
  return out;
}"""

def confere(m, res):
    falhas = []
    txt = res["r"]; plano = re.sub(r"<[^>]+>", "", txt)
    for p in GERAL_PROIBIDO:
        if re.search(r"\b" + re.escape(p) if p[0].isalpha() else re.escape(p), plano): falhas.append(f'texto proibido "{p}"')
    if m.get("comeca") and not (plano.startswith(m["comeca"]) or res["bruto"].startswith(m["comeca"])): falhas.append(f'deveria começar com "{m["comeca"]}"')
    for t in m.get("tem", []):
        if not any(alt.lower() in plano.lower() for alt in t.split("|")): falhas.append(f'faltou "{t}"')
    for t in m.get("nao", []):
        if t.lower() in plano.lower() if t != t.upper() else t in plano: falhas.append(f'não deveria ter "{t}"')
    for b in m.get("botao", []):
        if b not in res["botoes"]: falhas.append(f'faltou o botão "{b}" (veio: {res["botoes"]})')
    for b in m.get("sem_botao", []):
        if b in res["botoes"]: falhas.append(f'botão indevido "{b}"')
    return falhas

async def main():
    url = sys.argv[sys.argv.index("--url") + 1] if "--url" in sys.argv else "file://" + os.path.join(os.path.dirname(AQUI), "index.html")
    chrome = shutil.which("google-chrome") or shutil.which("chromium") or shutil.which("chromium-browser")
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=chrome, args=["--no-sandbox"]) if chrome else await p.chromium.launch()
        pg = await b.new_page(timezone_id="America/Sao_Paulo")
        erros_pagina = []; pg.on("pageerror", lambda e: erros_pagina.append(str(e)))
        await pg.goto(url); await pg.evaluate("localStorage.setItem('destina_mode','\"demo\"')"); await pg.reload(); await pg.wait_for_timeout(2500)
        total = ok = 0; relatorio = []
        for caso in CASOS:
            # saudações dependem da hora: fixa o relógio no fim da noite para "boa noite" bater
            res = await pg.evaluate(JS, caso)
            for m, r in zip(caso["msgs"], res):
                total += 1; f = confere(m, r)
                if f: relatorio.append(f'✗ {caso["nome"]} [{caso["persona"]}]\n    você: {m["q"]}\n    chat: {r["r"][:220]!r}\n    ' + "\n    ".join(f))
                else: ok += 1
        await b.close()
    print("\n".join(relatorio))
    if erros_pagina: print("Erros de JavaScript na página:", *erros_pagina[:5], sep="\n  ")
    print(f"\n{ok}/{total} respostas corretas em {len(CASOS)} conversas.")
    sys.exit(0 if ok == total and not erros_pagina else 1)

asyncio.run(main())
