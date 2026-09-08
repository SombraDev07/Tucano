"""Pagina do painel, embutida na biblioteca (M7).

Sem CDN, sem biblioteca de grafico: os graficos sao SVG desenhado a mao em
JavaScript. O painel roda em rede local ou sem rede nenhuma, e uma dependencia
externa quebraria isso.

O navegador nunca ve a tabela de origem. Cada widget recebe o **resultado
agregado** — doze pontos para um grafico de doze meses, mesmo que a fonte tenha
milhoes de linhas.
"""


def pagina(titulo: String) -> String:
    return String(_MOLDE).replace("{{TITULO}}", titulo)


comptime _MOLDE = """<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITULO}}</title>
<style>
  :root {
    --fundo: #f6f7f9; --cartao: #ffffff; --texto: #17191c; --suave: #6b7280;
    --borda: #e4e7eb; --tinta: #1f6feb; --tinta2: #16a34a; --tinta3: #d97706;
    --tinta4: #9333ea; --tinta5: #dc2626;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --fundo: #0f1115; --cartao: #171a21; --texto: #e6e8eb; --suave: #9aa2ad;
      --borda: #262b34; --tinta: #4c8dff;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px; background: var(--fundo); color: var(--texto);
    font: 14px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  header { display: flex; align-items: baseline; gap: 12px; margin-bottom: 20px; }
  h1 { font-size: 20px; margin: 0; font-weight: 650; letter-spacing: -0.01em; }
  .marca { color: var(--suave); font-size: 12px; }
  .filtros {
    display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 20px;
    padding: 14px 16px; background: var(--cartao); border: 1px solid var(--borda);
    border-radius: 10px;
  }
  .filtro { display: flex; flex-direction: column; gap: 4px; }
  .filtro label { font-size: 11px; color: var(--suave); text-transform: uppercase;
    letter-spacing: 0.04em; }
  select {
    background: var(--fundo); color: var(--texto); border: 1px solid var(--borda);
    border-radius: 6px; padding: 6px 10px; font: inherit; min-width: 150px;
  }
  .kpis { display: grid; gap: 12px; margin-bottom: 20px;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }
  .cartao {
    background: var(--cartao); border: 1px solid var(--borda); border-radius: 10px;
    padding: 16px;
  }
  .kpi .rotulo { font-size: 12px; color: var(--suave); }
  .kpi .valor { font-size: 26px; font-weight: 650; margin-top: 6px;
    font-variant-numeric: tabular-nums; letter-spacing: -0.02em; }
  .grade { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); }
  h2 { font-size: 13px; margin: 0 0 12px; font-weight: 600; color: var(--suave); }
  table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
  th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--borda);
    white-space: nowrap; }
  th { font-size: 11px; color: var(--suave); text-transform: uppercase;
    letter-spacing: 0.04em; }
  .rolagem { overflow-x: auto; max-height: 340px; overflow-y: auto; }
  .vazio { color: var(--suave); font-style: italic; padding: 12px 0; }
  .na { color: var(--suave); }
  footer { margin-top: 24px; color: var(--suave); font-size: 12px; }
  .erro { color: #dc2626; padding: 12px; }
</style>
</head>
<body>
<header>
  <h1>{{TITULO}}</h1>
  <span class="marca">Tucano</span>
</header>
<div class="filtros" id="filtros"></div>
<div class="kpis" id="kpis"></div>
<div class="grade" id="grade"></div>
<footer id="rodape"></footer>

<script>
const TINTAS = ["var(--tinta)","var(--tinta2)","var(--tinta3)","var(--tinta4)","var(--tinta5)"];
let painel = null;
const selecao = {};

const fmt = (v) => {
  if (v === null || v === undefined) return null;
  if (typeof v === "number") {
    if (Number.isInteger(v)) return v.toLocaleString("pt-BR");
    return v.toLocaleString("pt-BR", {maximumFractionDigits: 2});
  }
  return String(v);
};

function celula(v) {
  const t = fmt(v);
  if (t === null) return '<td class="na">—</td>';
  return "<td>" + t.replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c])) + "</td>";
}

function svgBarras(pontos) {
  const L = 560, A = 240, mE = 48, mB = 28, mT = 10, mD = 10;
  const lar = L - mE - mD, alt = A - mT - mB;
  const vals = pontos.map(p => p.y ?? 0);
  const max = Math.max(...vals, 0), min = Math.min(...vals, 0);
  const faixa = (max - min) || 1;
  const passo = lar / Math.max(pontos.length, 1);
  const larBarra = Math.max(2, passo * 0.62);
  let s = `<svg viewBox="0 0 ${L} ${A}" width="100%" role="img">`;
  s += `<line x1="${mE}" y1="${mT+alt}" x2="${L-mD}" y2="${mT+alt}" stroke="var(--borda)"/>`;
  pontos.forEach((p, i) => {
    const h = Math.abs((p.y ?? 0) - Math.min(min, 0)) / faixa * alt;
    const x = mE + i * passo + (passo - larBarra) / 2;
    const y = mT + alt - h;
    s += `<rect x="${x}" y="${y}" width="${larBarra}" height="${Math.max(h,1)}" rx="2" fill="var(--tinta)"><title>${p.x}: ${fmt(p.y) ?? "—"}</title></rect>`;
    if (pontos.length <= 16)
      s += `<text x="${x + larBarra/2}" y="${A-8}" font-size="10" fill="var(--suave)" text-anchor="middle">${p.x}</text>`;
  });
  s += `<text x="4" y="${mT+10}" font-size="10" fill="var(--suave)">${fmt(max) ?? ""}</text>`;
  return s + "</svg>";
}

function svgLinha(pontos) {
  const L = 560, A = 240, mE = 48, mB = 28, mT = 10, mD = 10;
  const lar = L - mE - mD, alt = A - mT - mB;
  const vals = pontos.map(p => p.y ?? 0);
  const max = Math.max(...vals, 0), min = Math.min(...vals, 0);
  const faixa = (max - min) || 1;
  const passo = pontos.length > 1 ? lar / (pontos.length - 1) : 0;
  const px = (i) => mE + i * passo;
  const py = (v) => mT + alt - ((v - min) / faixa) * alt;
  let d = "";
  pontos.forEach((p, i) => { d += (i ? " L " : "M ") + px(i) + " " + py(p.y ?? 0); });
  let s = `<svg viewBox="0 0 ${L} ${A}" width="100%" role="img">`;
  s += `<line x1="${mE}" y1="${mT+alt}" x2="${L-mD}" y2="${mT+alt}" stroke="var(--borda)"/>`;
  s += `<path d="${d}" fill="none" stroke="var(--tinta)" stroke-width="2" stroke-linejoin="round"/>`;
  pontos.forEach((p, i) => {
    s += `<circle cx="${px(i)}" cy="${py(p.y ?? 0)}" r="3" fill="var(--tinta)"><title>${p.x}: ${fmt(p.y) ?? "—"}</title></circle>`;
    if (pontos.length <= 16)
      s += `<text x="${px(i)}" y="${A-8}" font-size="10" fill="var(--suave)" text-anchor="middle">${p.x}</text>`;
  });
  s += `<text x="4" y="${mT+10}" font-size="10" fill="var(--suave)">${fmt(max) ?? ""}</text>`;
  return s + "</svg>";
}

function svgPizza(pontos) {
  const T = 240, r = 92, cx = T/2, cy = T/2;
  const total = pontos.reduce((a, p) => a + Math.abs(p.y ?? 0), 0) || 1;
  let ang = -Math.PI / 2;
  let s = `<svg viewBox="0 0 ${T*2.1} ${T}" width="100%" role="img">`;
  pontos.forEach((p, i) => {
    const frac = Math.abs(p.y ?? 0) / total;
    const fim = ang + frac * Math.PI * 2;
    const grande = frac > 0.5 ? 1 : 0;
    const x1 = cx + r*Math.cos(ang), y1 = cy + r*Math.sin(ang);
    const x2 = cx + r*Math.cos(fim), y2 = cy + r*Math.sin(fim);
    const cor = TINTAS[i % TINTAS.length];
    // fatia unica: um arco de 2pi comeca e termina no mesmo ponto e nao desenha
    if (frac > 0.999) {
      s += `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${cor}" opacity="0.9"><title>${p.x}: ${fmt(p.y) ?? "—"}</title></circle>`;
    } else {
      s += `<path d="M ${cx} ${cy} L ${x1} ${y1} A ${r} ${r} 0 ${grande} 1 ${x2} ${y2} Z" fill="${cor}" opacity="0.9"><title>${p.x}: ${fmt(p.y) ?? "—"}</title></path>`;
    }
    s += `<rect x="${T + 10}" y="${18 + i*22}" width="10" height="10" rx="2" fill="${cor}"/>`;
    s += `<text x="${T + 26}" y="${27 + i*22}" font-size="11" fill="var(--texto)">${p.x} — ${fmt(p.y) ?? "—"}</text>`;
    ang = fim;
  });
  return s + "</svg>";
}

function desenhar(dados) {
  const kpis = document.getElementById("kpis");
  const grade = document.getElementById("grade");
  kpis.innerHTML = ""; grade.innerHTML = "";

  dados.widgets.forEach(w => {
    if (w.tipo === "kpi") {
      const d = document.createElement("div");
      d.className = "cartao kpi";
      d.innerHTML = `<div class="rotulo">${w.titulo}</div><div class="valor">${fmt(w.valor) ?? "—"}</div>`;
      kpis.appendChild(d);
      return;
    }
    const d = document.createElement("div");
    d.className = "cartao";
    if (w.tipo === "grafico") {
      const corpo = w.pontos.length
        ? (w.forma === "linha" ? svgLinha(w.pontos)
          : w.forma === "pizza" ? svgPizza(w.pontos) : svgBarras(w.pontos))
        : '<div class="vazio">sem dados para os filtros atuais</div>';
      d.innerHTML = `<h2>${w.titulo}</h2>${corpo}`;
    } else {
      let t = "";
      if (w.linhas.length) {
        t = "<div class='rolagem'><table><thead><tr>" +
            w.colunas.map(c => "<th>" + c + "</th>").join("") +
            "</tr></thead><tbody>" +
            w.linhas.map(l => "<tr>" + w.colunas.map(c => celula(l[c])).join("") + "</tr>").join("") +
            "</tbody></table></div>";
      } else {
        t = '<div class="vazio">sem dados para os filtros atuais</div>';
      }
      d.innerHTML = `<h2>${w.titulo}</h2>${t}`;
    }
    grade.appendChild(d);
  });

  document.getElementById("rodape").textContent =
    `${dados.linhas_fonte.toLocaleString("pt-BR")} linhas na fonte · ` +
    `${dados.linhas_filtradas.toLocaleString("pt-BR")} apos os filtros · ` +
    `${dados.bytes_resposta.toLocaleString("pt-BR")} bytes trafegados`;
}

async function atualizar() {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(selecao)) if (v) q.set(k, v);
  const r = await fetch("/api/dados?" + q.toString());
  const dados = await r.json();
  if (dados.erro) {
    document.getElementById("grade").innerHTML = '<div class="erro">' + dados.erro + "</div>";
    return;
  }
  desenhar(dados);
}

async function iniciar() {
  painel = await (await fetch("/api/painel")).json();
  const cx = document.getElementById("filtros");
  if (!painel.filtros.length) { cx.style.display = "none"; }
  painel.filtros.forEach(f => {
    const d = document.createElement("div");
    d.className = "filtro";
    const opcoes = ['<option value="">todos</option>']
      .concat(f.valores.map(v => `<option value="${v}">${v}</option>`)).join("");
    d.innerHTML = `<label for="f_${f.coluna}">${f.coluna}</label>
      <select id="f_${f.coluna}">${opcoes}</select>`;
    cx.appendChild(d);
    d.querySelector("select").addEventListener("change", e => {
      selecao[f.coluna] = e.target.value;
      atualizar();
    });
  });
  atualizar();
}

iniciar();
</script>
</body>
</html>
"""
