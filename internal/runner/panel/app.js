// gentle-factory panel: read-only views over the receipt stores served by `factory panel`.
// No framework and no build step; every value from the API is inserted as text, never as HTML.
"use strict";

const REFRESH_MS = 4000;
const SVG = "http://www.w3.org/2000/svg";
const view = document.getElementById("view");
let timer = null;
let selected = null; // {path, node, attempt, tab}

// h builds an element: h("div", {class: "x", onclick: fn}, child, "text", ...).
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "style") el.style.cssText = v; // CSSOM: allowed by the panel's CSP, unlike a style attribute
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c === undefined || c === null || c === false) continue;
    el.append(c instanceof Node ? c : String(c));
  }
  return el;
}
function s(tag, attrs, ...children) {
  const el = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v);
  }
  for (const c of children.flat(Infinity)) if (c != null) el.append(c instanceof Node ? c : String(c));
  return el;
}

async function api(path) {
  const r = await fetch(path, { cache: "no-store" });
  if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
  return r.json();
}

// Only http(s) links from receipts become hrefs.
function safeURL(u) {
  return typeof u === "string" && /^https?:\/\//.test(u) ? u : null;
}
function money(x) { return "$" + (x || 0).toFixed(2); }
function dur(ms) {
  const sec = Math.round((ms || 0) / 1000);
  if (sec < 60) return sec + "s";
  const m = Math.floor(sec / 60);
  if (m < 60) return m + "m " + (sec % 60) + "s";
  return Math.floor(m / 60) + "h " + (m % 60) + "m";
}
function ago(iso) {
  const t = Date.parse(iso);
  if (!t || t < 0) return "-";
  return dur(Date.now() - t) + " ago";
}
function badge(status) { return h("span", { class: "badge s-" + (status || "none") }, (status || "none").replace("_", " ")); }
function issueLabel(run) {
  const n = run.issue && run.issue.number;
  if (!run.repository) return h("span", { class: "muted" }, "starting (no receipt yet)");
  const text = run.repository + (n ? "#" + n : "");
  const url = run.issue && safeURL(run.issue.url);
  return url ? h("a", { href: url, target: "_blank", rel: "noopener noreferrer", onclick: (e) => e.stopPropagation() }, text) : text;
}
function cards(t) {
  const items = [["runs", t.runs], ["attempts", t.attempts], ["failures", t.failures], ["decisions", t.decisions],
    ["retries", t.retries], ["cost (list price)", money(t.cost_usd)], ["agent time", dur(t.duration_ms)]];
  return h("div", { class: "cards" }, items.filter(([, v]) => v !== undefined)
    .map(([k, v]) => h("div", { class: "card" }, h("div", { class: "v" }, v), h("div", { class: "k" }, k))));
}

function setTab(name) {
  for (const a of document.querySelectorAll("nav a")) a.classList.toggle("active", a.dataset.tab === name);
}
function stamp() { document.getElementById("refresh").textContent = "updated " + new Date().toLocaleTimeString(); }

async function updateDecisionCount() {
  try {
    const d = await api("/api/decisions");
    const el = document.getElementById("decision-count");
    el.hidden = d.decisions.length === 0;
    el.textContent = d.decisions.length;
  } catch (_) { /* the main view reports errors */ }
}

// ---- runs ------------------------------------------------------------------
async function renderRuns() {
  setTab("runs");
  delete view.dataset.run;
  const data = await api("/api/runs");
  const rows = data.runs.map((r) => h("tr", { class: "click", onclick: () => { location.hash = "#/run/" + r.path; } },
    h("td", {}, issueLabel(r)),
    h("td", { class: "mono small" }, r.run_id),
    h("td", {}, badge(r.status), r.silent ? h("span", { class: "silent", title: "No file changed for longer than the longest node timeout: the runner may have died." }, "silent") : null),
    h("td", {}, r.node || "-"),
    h("td", { class: "num" }, money(r.cost_usd)),
    h("td", { class: "num" }, dur(r.duration_ms)),
    h("td", { class: "num" }, r.attempts),
    h("td", { class: "small muted" }, ago(r.updated_at)),
    h("td", {}, safeURL(r.pr_url) ? h("a", { href: r.pr_url, target: "_blank", rel: "noopener noreferrer", onclick: (e) => e.stopPropagation() }, "PR") : "")));
  view.replaceChildren(
    h("h1", {}, "Runs"),
    h("div", { class: "muted small" }, data.factory + " · " + data.runs_dirs.join(" · ")),
    cards(data.totals),
    data.runs.length === 0 ? h("div", { class: "empty" }, "No runs in these receipt stores yet.") :
      h("table", {}, h("thead", {}, h("tr", {}, ["issue", "run", "status", "last node"].map((x) => h("th", {}, x)),
        ["cost", "duration", "attempts"].map((x) => h("th", { class: "num" }, x)), h("th", {}, "updated"), h("th", {}, ""))),
      h("tbody", {}, rows)));
}

// ---- nodes (the summary numbers across runs) --------------------------------
async function renderNodes() {
  setTab("nodes");
  delete view.dataset.run;
  const data = await api("/api/runs");
  const ids = Object.keys(data.nodes).sort();
  view.replaceChildren(h("h1", {}, "Nodes across runs"),
    h("div", { class: "muted small" }, "The same numbers as `factory summary`, over every runs dir shown."),
    cards(data.totals),
    ids.length === 0 ? h("div", { class: "empty" }, "No receipts yet.") :
      h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "node"),
        ["attempts", "failures", "decisions", "retries", "cost", "duration"].map((x) => h("th", { class: "num" }, x)))),
      h("tbody", {}, ids.map((id) => {
        const n = data.nodes[id];
        return h("tr", {}, h("td", {}, id), h("td", { class: "num" }, n.attempts), h("td", { class: "num" }, n.failures),
          h("td", { class: "num" }, n.decisions), h("td", { class: "num" }, n.retries), h("td", { class: "num" }, money(n.cost_usd)),
          h("td", { class: "num" }, dur(n.duration_ms)));
      }))));
}

// ---- decisions -------------------------------------------------------------
async function renderDecisions() {
  setTab("decisions");
  delete view.dataset.run;
  const data = await api("/api/decisions");
  view.replaceChildren(h("h1", {}, "Waiting on the owner"),
    h("div", { class: "muted small" }, "Every run parked on a DECISION question, oldest first. To answer: edit the design comment and put the factory:ready label back."),
    h("div", { style: "height:12px" }),
    data.decisions.length === 0 ? h("div", { class: "empty" }, "Nothing is waiting on you.") :
      data.decisions.map((d) => h("div", { class: "decision" },
        h("div", {}, issueLabel(d), "  ", h("span", { class: "muted" }, "· node " + d.node)),
        h("div", { class: "q" }, d.question || "(no question recorded)"),
        h("div", { class: "meta" }, h("span", {}, "waiting " + dur(d.age_seconds * 1000)),
          h("a", { href: "#/run/" + d.path }, "open run " + d.run_id)))));
}

// ---- one run ---------------------------------------------------------------
const STATUS_COLOR = { success: "--green", failure: "--red", needs_decision: "--amber", misconfigured: "--purple" };

function drawGraph(g, path) {
  const W = 150, H = 86, GAP = 70, CHIP = 26, PAD = 20;
  const widths = g.nodes.map((n) => Math.max(W, 24 + n.attempts.length * (CHIP + 4)));
  const xs = [];
  let x = PAD;
  for (const w of widths) { xs.push(x); x += w + GAP; }
  const retries = g.edges.filter((e) => e.kind === "retry");
  const top = PAD + 40 + retries.length * 22;
  const width = x - GAP + PAD;
  const height = top + H + PAD;
  const pos = {};
  g.nodes.forEach((n, i) => { pos[n.id] = { x: xs[i], w: widths[i], cx: xs[i] + widths[i] / 2 }; });
  const svg = s("svg", { width, height, viewBox: `0 0 ${width} ${height}`, role: "img", "aria-label": "pipeline graph" });
  svg.append(s("defs", {},
    s("marker", { id: "arrow", viewBox: "0 0 10 10", refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: "auto-start-reverse" },
      s("path", { d: "M0,0 L10,5 L0,10 z", fill: "#8a90a3" })),
    s("marker", { id: "arrow-amber", viewBox: "0 0 10 10", refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: "auto-start-reverse" },
      s("path", { d: "M0,0 L10,5 L0,10 z", fill: "#e0a94a" }))));
  const ran = (id) => { const n = g.nodes.find((m) => m.id === id); return n && n.attempts.length > 0; };
  for (const e of g.edges.filter((e) => e.kind === "next")) {
    const a = pos[e.from], b = pos[e.to];
    if (!a || !b) continue;
    svg.append(s("line", { class: "edge" + (ran(e.to) ? " done" : ""), x1: a.x + a.w, y1: top + H / 2, x2: b.x - 4, y2: top + H / 2, "marker-end": "url(#arrow)" }));
  }
  retries.forEach((e, i) => {
    const a = pos[e.from], b = pos[e.to];
    if (!a || !b) return;
    const lift = top - 26 - i * 22;
    const d = `M${a.cx},${top} C${a.cx},${lift} ${b.cx},${lift} ${b.cx},${top - 3}`;
    const taken = e.taken > 0;
    svg.append(s("path", { class: "retry" + (taken ? " taken" : ""), d, "marker-end": taken ? "url(#arrow-amber)" : "url(#arrow)" },
      s("title", {}, `${e.from} sends work back to ${e.to} on failure` + (taken ? ` (happened ${e.taken}×)` : " (did not happen)"))));
    svg.append(s("text", { class: "retry-label" + (taken ? "" : " idle"), x: (a.cx + b.cx) / 2, y: 0.25 * top + 0.75 * lift - 6, "text-anchor": "middle" },
      taken ? `↺ retry ×${e.taken}` : "retry"));
  });
  g.nodes.forEach((n) => {
    const p = pos[n.id];
    const current = n.id === g.current;
    const last = n.attempts[n.attempts.length - 1];
    const box = s("rect", { class: "node-box" + (current ? " current" : ""), x: p.x, y: top, width: p.w, height: H, rx: 10 });
    if (last && !current) box.style.stroke = `var(${STATUS_COLOR[last.status] || "--gray"})`;
    svg.append(box);
    svg.append(s("text", { class: "node-title", x: p.x + 12, y: top + 22 }, n.id));
    svg.append(s("text", { class: "node-sub", x: p.x + 12, y: top + 38 },
      (n.kind || "?") + (n.role ? " · " + n.role : "") + (n.in_spec ? "" : " · not in spec") + (current ? " · last" : "")));
    if (n.attempts.length === 0) svg.append(s("text", { class: "node-sub", x: p.x + 12, y: top + 66 }, "not run"));
    n.attempts.forEach((a, k) => {
      const cx = p.x + 12 + k * (CHIP + 4);
      const isSel = selected && selected.path === path && selected.node === n.id && selected.attempt === a.attempt;
      const chip = s("g", { class: "chip" + (isSel ? " selected" : ""), tabindex: 0,
        onclick: () => selectAttempt(path, n.id, a.attempt),
        onkeydown: (ev) => { if (ev.key === "Enter") selectAttempt(path, n.id, a.attempt); } },
      s("title", {}, `${n.id} attempt ${a.attempt}: ${a.status}` + (a.terminal_reason ? ` (${a.terminal_reason})` : "") + ` · step ${a.seq}`),
      s("rect", { x: cx, y: top + 50, width: CHIP, height: 24, rx: 5, fill: `var(${STATUS_COLOR[a.status] || "--gray"})` }),
      s("text", { x: cx + CHIP / 2, y: top + 66, "text-anchor": "middle" }, "#" + a.attempt));
      svg.append(chip);
    });
  });
  const legend = h("div", { class: "legend" },
    [["success", "--green"], ["failure", "--red"], ["needs decision", "--amber"], ["misconfigured", "--purple"]]
      .map(([k, c]) => h("span", { style: `--c: var(${c})` }, k)),
    h("span", { style: "--c: var(--blue)" }, "last node"),
    h("span", { style: "--c: var(--amber)" }, "retry edge that happened (dashed: possible, not taken)"),
    h("span", { class: "muted", style: "--c: transparent" }, "click an attempt to inspect it"));
  return h("div", { class: "graph-wrap" }, svg, legend);
}

function kvItem(k, v) {
  return h("div", {}, h("div", { class: "k" }, k), h("div", { class: "v" }, v === undefined || v === null || v === "" ? "-" : String(v)));
}

async function selectAttempt(path, node, attempt, tab) {
  selected = { path, node, attempt, tab: tab || (selected && selected.tab) || "receipt" };
  for (const c of document.querySelectorAll(".chip")) c.classList.remove("selected");
  await renderDetail();
  if (location.hash.startsWith("#/run/")) {
    history.replaceState(null, "", `#/run/${path}/${node}/${attempt}`);
    const cur = await api("/api/runs/" + path).catch(() => null);
    if (cur) document.getElementById("graph").replaceChildren(drawGraph(cur.graph, path));
  }
}

async function renderDetail() {
  const box = document.getElementById("detail");
  if (!box || !selected) return;
  let d;
  try {
    d = await api(`/api/runs/${selected.path}/attempts/${selected.node}/${selected.attempt}`);
  } catch (e) {
    box.replaceChildren(h("div", { class: "detail" }, h("div", { class: "detail-head error" }, e.message)));
    return;
  }
  const r = d.receipt;
  const t = r.telemetry || {};
  const tok = t.tokens || {};
  const vcs = (r.references && r.references.vcs) || {};
  const tabs = [
    ["receipt", "Receipt", true],
    ["output", "Output", d.output !== undefined],
    ["log", "Log", d.log !== undefined],
    ["feedback", "Feedback", d.feedback !== undefined || d.sent_back_by !== undefined],
  ];
  if (!tabs.find(([k, , on]) => k === selected.tab && on)) selected.tab = "receipt";
  let body;
  switch (selected.tab) {
    case "output":
      body = [h("div", { class: "muted small", style: "padding:10px 14px 0" }, "outputs/" + selected.node + ".md: " + (d.output_note || "")), h("pre", { class: "text" }, d.output)];
      break;
    case "log":
      body = h("pre", { class: "text" }, d.log);
      break;
    case "feedback":
      body = [d.sent_back_by ? h("div", { class: "callout red", style: "margin:12px 14px" },
        `Sent back by ${d.sent_back_by.node} attempt ${d.sent_back_by.attempt}:\n${d.sent_back_by.reason}`) : null,
      d.feedback !== undefined ? [h("div", { class: "muted small", style: "padding:0 14px" }, "feedback/" + selected.node + ".txt (what this attempt was given):"), h("pre", { class: "text" }, d.feedback)] : null];
      break;
    default:
      body = [
        h("div", { class: "kv" },
          kvItem("status", r.outcome.status), kvItem("terminal reason", r.outcome.terminal_reason),
          kvItem("exit code", r.outcome.exit_code), kvItem("model", t.request_model),
          kvItem("turns", t.num_turns), kvItem("cost (list price)", t.total_cost_usd != null ? money(t.total_cost_usd) : null),
          kvItem("duration", dur(t.duration_ms)), kvItem("tokens in / out / total", tok.total_tokens != null ? `${tok.input_tokens} / ${tok.output_tokens} / ${tok.total_tokens}` : null),
          kvItem("base commit", (vcs.base_commit || "").slice(0, 12)), kvItem("head commit", (vcs.head_commit || "").slice(0, 12)),
          kvItem("branch", vcs.branch), kvItem("engine", r.execution && r.execution.engine),
          kvItem("trace id", t.trace_id), kvItem("span id", t.span_id), kvItem("failure signature", (r.failure_signature || "").slice(0, 16))),
        r.outcome.status !== "success" && d.reason ? h("div", { class: "callout" + (r.outcome.status === "needs_decision" ? "" : " red"), style: "margin:0 14px 12px" }, d.reason) : null,
        r.gate ? h("div", { class: "kv" }, kvItem("gate", r.gate.status), kvItem("checks passed", (r.gate.checks_passed || []).join(", ")),
          kvItem("checks failed", (r.gate.checks_failed || []).join(", "))) : null,
        r.notes ? [h("div", { class: "muted small", style: "padding:0 14px" }, "notes"), h("pre", { class: "text" }, r.notes)] : null,
      ];
  }
  box.replaceChildren(h("div", { class: "detail" },
    h("div", { class: "detail-head" }, h("strong", {}, `${selected.node} · attempt ${selected.attempt}`), badge(r.outcome.status),
      h("span", { class: "muted small" }, "step " + d.seq)),
    h("div", { class: "tabs" }, tabs.map(([k, label, on]) => h("button", {
      class: k === selected.tab ? "active" : null, disabled: !on,
      onclick: () => { selected.tab = k; renderDetail(); } }, label))),
    body));
}

async function renderRun(path, node, attempt) {
  setTab("runs");
  const data = await api("/api/runs/" + path);
  const r = data.run;
  if (node && attempt && !(selected && selected.path === path && selected.node === node && selected.attempt === +attempt)) {
    selected = { path, node, attempt: +attempt, tab: "receipt" };
  } else if (!selected || selected.path !== path) {
    selected = null;
  }
  const head = h("div", { class: "run-head" },
    h("div", {}, h("h1", {}, issueLabel(r), "  ", badge(r.status), r.silent ? h("span", { class: "silent" }, "silent: the runner may have died") : null),
      h("div", { class: "meta mono" }, r.run_id),
      h("div", { class: "meta" }, `last node ${r.node || "-"} · updated ${ago(r.updated_at)} · ${r.runs_dir}`)),
    h("div", {}, safeURL(r.pr_url) ? h("a", { href: r.pr_url, target: "_blank", rel: "noopener noreferrer" }, "Draft PR ↗") : null,
      " ", h("a", { href: "#/" }, "← all runs")));
  const callout = r.status === "needs_decision" ? h("div", { class: "callout" }, "DECISION: " + r.reason)
    : r.status === "stopped" ? h("div", { class: "callout red" }, `Stopped at ${r.node} (${r.terminal_reason}): ${r.reason}`)
      : r.error ? h("div", { class: "callout red" }, r.error) : null;
  const ids = Object.keys(data.nodes);
  const nodeTable = ids.length === 0 ? null : h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "node"),
    ["attempts", "failures", "decisions", "retries", "cost", "duration"].map((x) => h("th", { class: "num" }, x)))),
  h("tbody", {}, data.graph.nodes.filter((n) => data.nodes[n.id]).map((n) => {
    const s2 = data.nodes[n.id];
    return h("tr", {}, h("td", {}, n.id), h("td", { class: "num" }, s2.attempts), h("td", { class: "num" }, s2.failures),
      h("td", { class: "num" }, s2.decisions), h("td", { class: "num" }, s2.retries), h("td", { class: "num" }, money(s2.cost_usd)),
      h("td", { class: "num" }, dur(s2.duration_ms)));
  })));
  const top = [head, callout, cards(data.totals)];
  const graph = drawGraph(data.graph, path);
  if (view.dataset.run === path) {
    // Refresh in place: the open attempt (and the scroll of its log) stays untouched.
    document.getElementById("run-top").replaceChildren(...top.filter(Boolean));
    document.getElementById("graph").replaceChildren(graph);
    document.getElementById("node-table").replaceChildren(...[nodeTable].filter(Boolean));
    return;
  }
  view.dataset.run = path;
  view.replaceChildren(h("div", { id: "run-top" }, top), h("h2", {}, "Pipeline"), h("div", { id: "graph" }, graph),
    h("div", { id: "detail" }), h("h2", {}, "Per node"), h("div", { id: "node-table" }, nodeTable));
  if (selected) await renderDetail();
}

// ---- routing and refresh ---------------------------------------------------
async function route(refresh) {
  const hash = location.hash || "#/";
  const m = hash.match(/^#\/run\/(\d+)\/([A-Za-z0-9][A-Za-z0-9_.-]*)(?:\/([a-z0-9_-]+)\/(\d+))?$/);
  try {
    if (m) await renderRun(m[1] + "/" + m[2], m[3], m[4]);
    else if (hash === "#/decisions") await renderDecisions();
    else if (hash === "#/nodes") await renderNodes();
    else await renderRuns();
    stamp();
  } catch (e) {
    if (!refresh) view.replaceChildren(h("p", { class: "error" }, String(e.message || e)));
    else document.getElementById("refresh").textContent = "refresh failed: " + (e.message || e);
  }
  updateDecisionCount();
}

function schedule() {
  clearTimeout(timer);
  timer = setTimeout(async () => {
    // A refresh never steals a text selection or the scroll of an open log.
    if (!document.hidden && String(window.getSelection()) === "") await route(true);
    schedule();
  }, REFRESH_MS);
}

window.addEventListener("hashchange", () => { route(false); schedule(); });
route(false);
schedule();
