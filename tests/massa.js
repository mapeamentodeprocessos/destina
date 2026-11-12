// Gerador de perguntas em massa para o assistente do Destina (roda dentro da página, no modo demonstração).
// window.MASSA.rodar(n, semente) -> {total, ok, porIntencao, porRuido, falhas:[...]}
(() => {
  let seed = 1;
  const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
  const pick = a => a[Math.floor(rnd() * a.length)];
  const ACENTO = s => s.normalize("NFD").replace(/[̀-ͯ]/g, "");
  const VIZ = {a:"qsz", s:"adw", d:"sfe", f:"dgr", g:"fht", h:"gjy", j:"hku", k:"jli", l:"ko", q:"wa", w:"qes", e:"wrd", r:"etf", t:"ryg", y:"tuh", u:"yij", i:"uok", o:"ipl", p:"o", z:"xa", x:"zc", c:"xv", v:"cb", b:"vn", n:"bm", m:"n"};
  const typo = w => {
    if (w.length < 4) return w;
    const i = 1 + Math.floor(rnd() * (w.length - 2)), k = rnd();
    if (k < .3) return w.slice(0, i) + w[i + 1] + w[i] + w.slice(i + 2);            // troca
    if (k < .55) return w.slice(0, i) + w.slice(i + 1);                              // falta letra
    if (k < .75) return w.slice(0, i) + w[i] + w.slice(i);                           // letra dobrada
    const c = w[i].toLowerCase(); return VIZ[c] ? w.slice(0, i) + pick(VIZ[c]) + w.slice(i + 1) : w; // tecla vizinha
  };
  const ABREV = [[/\bvocê\b/g, "vc"], [/\bque\b/g, "q"], [/\bquantos\b/g, "qts"], [/\bquanto\b/g, "qto"], [/\bpara\b/g, "p/"], [/\bpara\b/g, "pra"], [/\btambém\b/g, "tb"], [/\bpor favor\b/g, "pfv"], [/\bestá\b/g, "ta"], [/\bnão\b/g, "nao"], [/\bdisponível\b/g, "disponivel"]];
  const ENFEITE_I = ["", "", "", "me diz ", "por favor, ", "ei, ", "assistente, ", "preciso saber: ", "uma dúvida: ", "oi, "];
  const ENFEITE_F = ["", "", "", "?", "??", " por favor", " aí", " hoje", "!", " rapidinho"];

  // materiais do cenário de demonstração e jeitos populares de chamá-los
  const MAT = [["projetor", "data show", "datashow", "projetores"], ["cadeira", "cadeiras", "cadeira giratória"], ["notebook", "notebooks", "laptop"], ["geladeira", "refrigerador", "geladeiras"],
    ["ar condicionado", "ar-condicionado", "split", "ar condicionados"], ["mesa", "mesas", "mesa de escritório"], ["microscópio", "microscópios"], ["bebedouro", "bebedouros"], ["monitor", "monitores"],
    ["estante", "estantes"], ["armário", "armários"], ["impressora", "impressoras"], ["computador", "desktop", "computadores"], ["longarina", "longarinas"]];
  const UNI = ["CCEN", "CCS", "CT", "CCJ", "CCHLA", "STI", "Biblioteca Central", "CCSA", "CE"];
  const QTD = ["", "1 ", "2 ", "5 ", "10 ", "um ", "uma ", "dois ", "três ", "cinco ", "dez ", "vinte "];
  const T = {
    saldo: ["quantos {m} temos", "tem {m} disponível", "saldo de {m}", "quanto temos de {m}", "{m} disponíveis", "existe {m} na reserva", "ainda tem {m}", "qual a quantidade de {m}", "quantas {m} tem", "tem {m} sobrando", "temos {m}", "estoque de {m}"],
    destinar: ["quero mandar {q}{m} para o {u}", "preciso destinar {q}{m} para o {u}", "destinar {q}{m} para {u}", "quero fazer uma destinação de {q}{m} para o {u}", "envie {q}{m} ao {u}", "gostaria de destinar {q}{m} para o {u}", "o {u} precisa de {q}{m}, pode mandar?", "libere {q}{m} para o {u}", "manda {q}{m} pro {u}", "vamos destinar {q}{m} para o {u}"],
    total: ["quantos bens temos", "total de bens na reserva", "tamanho da reserva", "quantos itens tem a reserva", "quantos bens no total", "quanto temos na reserva"],
    valor: ["quanto vale a reserva", "valor total da reserva", "qual o valor do estoque", "quanto dinheiro tem parado na reserva"],
    pendencias: ["minhas pendências", "o que eu preciso fazer", "quais as pendências", "tenho alguma pendência", "o que tenho para hoje", "tarefas pendentes"],
    plano: ["situação do PD 0009/2026", "onde está o PD 0009/2026", "como está o plano PD 0009/2026", "status do PD 0009/2026", "PD 0009/2026"],
    unidade: ["o que o {u} recebeu", "planos do {u}", "como está o {u}", "o que tem para o {u}", "entregas para o {u}"],
    atrasos: ["planos atrasados", "o que está atrasado", "tem algum atraso", "onde está travado", "gargalos"],
    parados: ["o que está parado", "bens parados", "o que está parado há mais tempo", "itens mais antigos na reserva"],
    garantia: ["garantia vencendo", "o que perde a garantia", "garantias a vencer", "itens com garantia vencida"],
    empenhos: ["empenhos aguardando tombamento", "o que falta tombar", "situação dos empenhos", "empenhos recebidos"],
    saudacao: ["oi", "olá", "bom dia", "boa tarde", "boa noite", "olá, tudo bem?", "oi assistente", "e aí"],
    cortesia: ["obrigado", "valeu", "muito obrigada", "agradeço", "obrigado pela ajuda"],
    adiar: ["deixa pra depois", "vejo depois", "agora não", "fica pra depois", "desconsidere"],
    campos: ["quantos empenhos temos", "quais empenhos temos disponíveis", "quais processos", "empenho das {m}", "quais pregões", "quais requisições", "qual empenho tem mais saldo", "empenhos com saldo"],
    saidas: ["quais saídas tivemos", "qual a última saída", "para onde foram os {m}", "saídas de 2026", "lista das saídas"],
    atributos: ["qual a especificação do {m}", "valor médio do {m}", "onde fica o {m}", "quando chegou o {m}", "qual o preço do {m}"]
  };
  const OK = {
    saldo: (r, c) => /dispon/i.test(r) && !/^Não há temos/.test(r),
    destinar: r => /^(\*\*[\d.]+ disponíveis\*\*|Temos \d+ opções|\*\*Só há|\*\*Não há)/.test(r),
    total: r => /bens sob guarda|sob guarda/.test(r),
    valor: r => /R\$/.test(r),
    pendencias: r => /pendênci/i.test(r),
    plano: r => /PD 0009\/2026/.test(r),
    unidade: (r, c) => r.toUpperCase().includes(c.u.toUpperCase()) || /\(([A-Z]{2,})\)/.test(r) && r.includes("(" + c.u + ")"),
    atrasos: r => /prazo|atras/i.test(r),
    parados: r => /parad|há mais tempo/i.test(r),
    garantia: r => /garantia/i.test(r),
    empenhos: r => /empenho|tombament/i.test(r),
    saudacao: r => r.length < 140 && !/PD |pendênci|disponíve/i.test(r),
    cortesia: r => r.length < 140 && !/PD |disponíve/i.test(r),
    adiar: r => /depois|desconsider|deixei de lado|tudo bem|combinado/i.test(r),
    campos: r => /empenho|processo|pregão|requisiç/i.test(r) && !/bens sob guarda/.test(r),
    saidas: r => /saída|Saídas|Ainda não saiu|Nenhuma saída/.test(r),
    atributos: r => /especifica|Valor médio|fica em|Entradas de|não têm valor|sem especificação/i.test(r)
  };
  const QUEBRADO = /\bundefined\b|NaN|\[object|\bnull\b|&quot;|&amp;/;
  const NIVEIS = ["limpo", "sem acento", "abreviado", "1 erro de digitação", "2+ erros de digitação"];
  function gerar() {
    const it = pick(Object.keys(T)); const tpl = pick(T[it]);
    const m = pick(MAT), mm = pick(m), u = pick(UNI), q = pick(QTD);
    let s = pick(ENFEITE_I) + tpl.replace("{m}", mm).replace("{u}", u).replace("{q}", q) + pick(ENFEITE_F);
    const nivel = Math.floor(rnd() * NIVEIS.length);
    if (nivel >= 1) s = ACENTO(s);
    if (nivel === 2) ABREV.forEach(([re, v]) => { if (rnd() < .7) s = s.replace(re, v); });
    if (nivel >= 3) { const w = s.split(" "); const n = nivel === 3 ? 1 : 2 + Math.floor(rnd() * 2); for (let k = 0; k < n; k++) { const i = Math.floor(rnd() * w.length); if (!/PD|\d/.test(w[i])) w[i] = typo(w[i]); } s = w.join(" "); }
    if (rnd() < .3) s = s.toLowerCase(); else if (rnd() < .05) s = s.toUpperCase();
    return {q:s, intent:it, nivel:NIVEIS[nivel], u, m:m[0]};
  }
  async function rodar(n, semente = 1, persona = "u_pat") {
    seed = semente; await enterDemoPersona(persona, true);
    const res = {total:0, ok:0, porIntencao:{}, porRuido:{}, falhas:[]};
    for (let i = 0; i < n; i++) {
      const c = gerar(); AS.slot = null; AS.ctx = null; const msg = {actions:[], sug:null}; let r;
      try { r = String(await localAnswer(c.q, msg)); } catch (e) { r = "ERRO " + e.message; }
      r = r.replace(/&quot;/g, '"');
      const bom = !QUEBRADO.test(r) && !/^ERRO/.test(r) && OK[c.intent](r, c);
      res.total++; if (bom) res.ok++;
      const a = res.porIntencao[c.intent] = res.porIntencao[c.intent] || [0, 0]; a[0]++; if (bom) a[1]++;
      const b = res.porRuido[c.nivel] = res.porRuido[c.nivel] || [0, 0]; b[0]++; if (bom) b[1]++;
      if (!bom && res.falhas.length < 4000) res.falhas.push({intent:c.intent, nivel:c.nivel, q:c.q, r:r.slice(0, 160)});
    }
    return res;
  }
  window.MASSA = {rodar, gerar};
})();
