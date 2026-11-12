"""Roda N perguntas geradas (com erros de português, abreviações, nomes populares) em páginas paralelas.
Uso: python3 tests/rodar_massa.py 100000 [--paginas 6] [--minimo 0.95]
Saída: acerto por tipo de pedido e por nível de ruído, os padrões de falha mais comuns e tests/massa-falhas.json.
"""
import asyncio, json, os, shutil, sys, time, collections, re
from playwright.async_api import async_playwright

AQUI = os.path.dirname(os.path.abspath(__file__))
N = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 2000
PAG = int(sys.argv[sys.argv.index("--paginas") + 1]) if "--paginas" in sys.argv else 6
MIN = float(sys.argv[sys.argv.index("--minimo") + 1]) if "--minimo" in sys.argv else 0
LOTE = 500

async def trabalhador(b, k, fatias, acum):
    pg = await b.new_page(timezone_id="America/Sao_Paulo")
    await pg.goto("file://" + os.path.join(os.path.dirname(AQUI), "index.html"))
    await pg.evaluate("localStorage.setItem('destina_mode','\"demo\"')"); await pg.reload(); await pg.wait_for_timeout(2500)
    await pg.add_script_tag(path=os.path.join(AQUI, "massa.js"))
    for semente, n in fatias:
        r = await pg.evaluate("([n,s]) => MASSA.rodar(n, s)", [n, semente])
        acum.append(r)
    await pg.close()

async def main():
    t0 = time.time()
    fatias = [(1000 + i, min(LOTE, N - i * LOTE)) for i in range((N + LOTE - 1) // LOTE)]
    por = [fatias[i::PAG] for i in range(PAG)]
    acum = []
    ch = shutil.which("google-chrome") or shutil.which("chromium")
    async with async_playwright() as p:
        b = await (p.chromium.launch(executable_path=ch, args=["--no-sandbox"]) if ch else p.chromium.launch())
        await asyncio.gather(*[trabalhador(b, k, f, acum) for k, f in enumerate(por) if f])
        await b.close()
    tot = sum(r["total"] for r in acum); ok = sum(r["ok"] for r in acum)
    def soma(chave):
        d = collections.defaultdict(lambda: [0, 0])
        for r in acum:
            for k, (a, c) in r[chave].items(): d[k][0] += a; d[k][1] += c
        return d
    print(f"\n{tot} perguntas em {time.time() - t0:.0f}s · acerto geral {ok / tot:.1%}\n")
    print("Por tipo de pedido:")
    for k, (a, c) in sorted(soma("porIntencao").items(), key=lambda x: x[1][1] / x[1][0]): print(f"  {k:12} {c / a:6.1%}  ({a - c} falhas em {a})")
    print("\nPor nível de ruído:")
    for k, (a, c) in soma("porRuido").items(): print(f"  {k:24} {c / a:6.1%}")
    falhas = [f for r in acum for f in r["falhas"]]
    pad = collections.Counter((f["intent"], re.sub(r"\d[\d.]*", "#", f["r"][:45])) for f in falhas)
    print("\nPadrões de falha mais comuns (tipo · início da resposta):")
    for (it, ini), c in pad.most_common(25):
        ex = next(f for f in falhas if f["intent"] == it and re.sub(r"\d[\d.]*", "#", f["r"][:45]) == ini)
        print(f"  {c:5}× {it:10} {ini!r}\n         ex.: {ex['q']!r}")
    json.dump(falhas, open(os.path.join(AQUI, "massa-falhas.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    sys.exit(0 if ok / tot >= MIN else 1)

asyncio.run(main())
