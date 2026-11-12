"""Variações geradas: centenas de jeitos de pedir destinação, perguntar saldo e cumprimentar.
Regras gerais: pedido de destinação começa pela disponibilidade; pergunta de saldo responde saldo; cumprimento não traz pendências.
Uso: python3 tests/variacoes.py  (sai com código 1 se houver problema)
"""
import asyncio, json, os, re, shutil, itertools, random
from playwright.async_api import async_playwright
random.seed(7)
verbos = ["quero mandar {q}{i} para o {u}","preciso destinar {q}{i} para o {u}","destinar {q}{i} para {u}","quero fazer uma destinação de {q}{i} para o {u}","envie {q}{i} ao {u}","gostaria de destinar {q}{i} pro {u}","vamos mandar {q}{i} para a {u}","monte um plano com {q}{i} para o {u}","a {u} precisa de {q}{i}, pode mandar?","libere {q}{i} para o {u}"]
itens = ["projetor","data show","cadeira","cadeiras","notebook","notebooks","geladeira","ar condicionado","ar-condicionado","mesa","microscópio","bebedouro","switch","drone","impressora 3d","armário","estante","computador"]
qs = ["","um ","uma ","2 ","dez ","cinco ","30 "]
unis = ["CCEN","CCS","CT","Biblioteca Central","CCJ","STI","CCHLA","Prefeitura Universitária"]
pergs = ["quantos {i} temos","tem {i} disponível?","qual o saldo de {i}","{i} disponíveis","quanto temos de {i}?","existe {i} na reserva?"]
saud = ["olá","oi","boa noite","olá, boa noite","bom dia!","oi tudo bem?","e aí","boa tarde, tudo bem?","olá assistente"]
cases=[]
for v in verbos:
  for i in random.sample(itens,6):
    cases.append(("dest", v.format(q=random.choice(qs), i=i, u=random.choice(unis)), i))
for p_ in pergs:
  for i in itens: cases.append(("saldo", p_.format(i=i), i))
for s in saud: cases.append(("saud", s, ""))
JS = """async (cs) => { const out=[]; for (const pid of ['u_pat','u_reit']) { await enterDemoPersona(pid,true);
  for (const [k,q,i] of cs) { AS.slot=null; AS.ctx=null; const msg={actions:[],sug:null}; let r; try { r=String(await localAnswer(q,msg)); } catch(e){ r='ERRO: '+e.message; }
    out.push({pid,k,q,i,r:r.replace(/<[^>]+>/g,''),b:msg.actions.map(a=>a.rotulo)}); } } return out; }"""
async def main():
  async with async_playwright() as p:
    ch = shutil.which("google-chrome") or shutil.which("chromium"); b = await (p.chromium.launch(executable_path=ch, args=["--no-sandbox"]) if ch else p.chromium.launch()); pg=await b.new_page()
    await pg.goto("file://" + os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "index.html")); await pg.evaluate("localStorage.setItem('destina_mode','\"demo\"')"); await pg.reload(); await pg.wait_for_timeout(2500)
    res = await pg.evaluate(JS, cases); await b.close()
  bad=[]
  for x in res:
    r=x["r"]; prob=[]
    if re.search(r"\bundefined\b|NaN|\[object|ERRO:|\bnull\b", r): prob.append("texto quebrado")
    if x["k"]=="dest":
      if not (re.match(r"\*\*[\d.]+ disponíveis\*\*", r) or r.startswith("**Não há") or r.startswith("Temos ") or r.startswith("**Só há")): prob.append("não começou pela disponibilidade")
    if x["k"]=="saldo" and not re.search(r"disponíve|Não h|não há|Nenhum", r, re.I): prob.append("não respondeu saldo")
    if x["k"]=="saud" and (len(r)>120 or re.search(r"PD |pendên|disponíve", r)): prob.append("saudação com conteúdo")
    if prob: bad.append(f'{x["pid"]} | {x["q"]} → {r[:150]!r} | {", ".join(prob)}')
  print("\n".join(bad[:80])); print(len(res), "respostas;", len(bad), "problemas")
  import sys; sys.exit(1 if bad else 0)
asyncio.run(main())
