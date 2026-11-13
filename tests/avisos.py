"""Confere o sino de avisos: contagem por perfil, lista de demandas e alerta quando chega uma demanda nova.
Uso: python3 tests/avisos.py"""
import asyncio, os, shutil, sys
from playwright.async_api import async_playwright

URL = "file://" + os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "index.html")

async def main():
    chrome = shutil.which("google-chrome") or shutil.which("chromium") or shutil.which("chromium-browser")
    falhas = []
    def checa(cond, msg):
        print(("ok    " if cond else "FALHA ") + msg)
        if not cond: falhas.append(msg)
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=chrome, args=["--no-sandbox"]) if chrome else await p.chromium.launch()
        pg = await b.new_page(viewport={"width": 1400, "height": 900}); errs = []; pg.on("pageerror", lambda e: errs.append(str(e)))
        await pg.goto(URL); await pg.evaluate("localStorage.setItem('destina_mode','\"demo\"')"); await pg.reload(); await pg.wait_for_timeout(2500)
        entrar = lambda per: pg.evaluate(f"(async()=>{{ enterDemoPersona('{per}'); closeModal(); }})()")
        await entrar("u_alm"); await pg.wait_for_timeout(700)
        n = await pg.evaluate("demandas().filter(d => d.acao).length")
        badge = await pg.evaluate("document.querySelector('.sino .n')?.textContent")
        checa(n > 0 and badge == str(n), f"sino do Almoxarifado mostra {badge} e há {n} demandas")
        checa(await pg.locator(".av-novo").count() == 1, "resumo de demandas ao entrar")
        await pg.evaluate("document.querySelectorAll('.av-novo').forEach(x => x.remove())")
        await pg.click(".sino"); await pg.wait_for_timeout(300)
        checa(await pg.locator("#av-pop .av-it").count() >= n, "painel lista as demandas")
        await pg.keyboard.press("Escape"); await pg.wait_for_timeout(200)
        checa(await pg.locator("#av-pop").count() == 0, "Esc fecha o painel")
        await pg.evaluate("(()=>{ const p = Object.values(S.plans).find(p => p.status === 'AUTORIZACAO'); p.status = 'AUTORIZADO'; renderShell(); })()"); await pg.wait_for_timeout(400)
        txt = await pg.locator(".av-novo").inner_text() if await pg.locator(".av-novo").count() else ""
        checa("Nova demanda" in txt and "Iniciar separação" in txt, "alerta de nova demanda: " + txt.split("\n")[0])
        await pg.click(".av-novo [data-v]"); await pg.wait_for_timeout(400)
        checa((await pg.evaluate("location.hash")).startswith("#plano-"), "Ver abre o plano")
        await entrar("u_cons"); await pg.wait_for_timeout(500)
        checa(await pg.locator(".sino .n").count() == 0, "Consulta não tem demandas")
        checa(not errs, "sem erros na página " + str(errs))
        await b.close()
    print(f"\n{'Tudo certo' if not falhas else str(len(falhas)) + ' falha(s)'}.")
    sys.exit(1 if falhas else 0)

asyncio.run(main())
