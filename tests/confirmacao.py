"""Confere a pergunta de confirmação (estilo SIPAC) antes de gravar: Não e Esc cancelam, Sim executa.
Uso: python3 tests/confirmacao.py"""
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
        pg = await b.new_page(); errs = []; pg.on("pageerror", lambda e: errs.append(str(e)))
        await pg.goto(URL); await pg.evaluate("localStorage.setItem('destina_mode','\"demo\"')"); await pg.reload(); await pg.wait_for_timeout(2500)
        pid = await pg.evaluate("""(async()=>{ await enterDemoPersona('u_alm', true); await new Promise(r=>setTimeout(r,500));
          const p = Object.values(S.plans).find(p => p.status === 'AUTORIZADO'); location.hash = 'plano-' + p.id; return p.id; })()""")
        await pg.wait_for_timeout(800)
        st = lambda: pg.evaluate(f"S.plans['{pid}'].status")
        btn = pg.locator(f'[data-act="start-sep"][data-id="{pid}"]').first
        await btn.click(); await pg.wait_for_timeout(300)
        q = await pg.locator("#cf-q").text_content()
        checa("Deseja realmente iniciar a separação do PD" in q, "pergunta antes de iniciar a separação: " + q)
        await pg.click("#cf-nao"); await pg.wait_for_timeout(400)
        checa(await st() == "AUTORIZADO", "Não cancela")
        await btn.click(); await pg.wait_for_timeout(300); await pg.keyboard.press("Escape"); await pg.wait_for_timeout(300)
        checa(await st() == "AUTORIZADO", "Esc cancela")
        await btn.click(); await pg.wait_for_timeout(300); await pg.click("#cf-sim"); await pg.wait_for_timeout(900)
        checa(await st() == "SEPARACAO", "Sim executa")
        await pg.locator('[data-act="conferir"]').first.click(); await pg.wait_for_timeout(500)
        await pg.locator(".modal-f button").first.click(); await pg.wait_for_timeout(300)
        checa(await pg.locator("#cf-q").count() == 1, "botão de janela também pergunta")
        checa(await pg.locator("#modal-root .modal").count() == 1, "a janela continua aberta por baixo da pergunta")
        await pg.click("#cf-nao"); await pg.wait_for_timeout(200)
        await pg.locator('.modal-f [data-act="close"]').first.click(); await pg.wait_for_timeout(200)
        checa(await pg.locator("#cf-q").count() == 0 and await pg.locator("#modal-root .modal").count() == 0, "Fechar não pergunta")
        checa(not errs, "sem erros na página " + str(errs))
        await b.close()
    print(f"\n{'Tudo certo' if not falhas else str(len(falhas)) + ' falha(s)'}.")
    sys.exit(1 if falhas else 0)

asyncio.run(main())
