import { evaluateNote } from "./math.js?v=30213c1f40";

const REPO = "lsuryatej/jot";

// The tip jar. Empty keeps the line hidden; set it to a Buy Me a Coffee,
// Ko-fi or GitHub Sponsors link and the "buy me a coffee" line appears.
const TIP_URL = "";

if (TIP_URL) {
  document.getElementById("tip-link").href = TIP_URL;
  document.getElementById("tip-line").hidden = false;
}

// Storage can be unavailable (private windows, blocked site data), so every
// read and write is optional: the page works the same without it.
const store = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch { /* fine */ } },
};

// ---- The scratchpad -------------------------------------------------------

const scratch = document.getElementById("scratch");
const results = document.getElementById("pad-results");

const saved = store.get("jot-scratch");
if (saved !== null && saved.trim() !== "") scratch.value = saved;

function renderResults() {
  const answers = evaluateNote(scratch.value);
  results.replaceChildren(...answers.map((answer) => {
    const row = document.createElement("div");
    row.textContent = answer ?? "";
    return row;
  }));
  // Grow with the note so it never scrolls inside itself: one row per line.
  const lines = scratch.value.split("\n").length;
  scratch.style.height = `calc(var(--lh) * ${Math.max(3, lines)})`;
}

scratch.addEventListener("input", () => {
  renderResults();
  store.set("jot-scratch", scratch.value);
});
renderResults();

// ---- The checklist --------------------------------------------------------

document.querySelectorAll(".todo input").forEach((box, index) => {
  const key = `jot-todo-${index}`;
  const value = store.get(key);
  if (value !== null) box.checked = value === "1";
  box.addEventListener("change", () => store.set(key, box.checked ? "1" : "0"));
});

// ---- Paper ----------------------------------------------------------------

const PAPERS = ["cream", "white", "dark"];
const NAMES = { cream: "cream", white: "white", dark: "true dark" };
const paperName = document.getElementById("paper-name");
const picks = document.querySelectorAll(".paper-pick");
const themeColor = document.querySelectorAll('meta[name="theme-color"]');
const PAPER_HEX = { cream: "#F7F0E1", white: "#FFFFFF", dark: "#131315" };

function setPaper(paper, remember) {
  document.documentElement.setAttribute("data-paper", paper);
  paperName.textContent = NAMES[paper];
  picks.forEach((pick) => pick.setAttribute("aria-pressed", String(pick.dataset.paper === paper)));
  themeColor.forEach((meta) => meta.setAttribute("content", PAPER_HEX[paper]));
  if (remember) store.set("jot-paper", paper);
}

setPaper(document.documentElement.getAttribute("data-paper") || "cream", false);
document.getElementById("paper-button").addEventListener("click", () => {
  const current = document.documentElement.getAttribute("data-paper");
  setPaper(PAPERS[(PAPERS.indexOf(current) + 1) % PAPERS.length], true);
});
picks.forEach((pick) => pick.addEventListener("click", () => setPaper(pick.dataset.paper, true)));

// ---- Copy the brew command --------------------------------------------------

const copyButton = document.getElementById("copy-brew");
copyButton.addEventListener("click", async () => {
  const command = document.getElementById("brew").textContent;
  try {
    await navigator.clipboard.writeText(command);
    copyButton.textContent = "copied";
    copyButton.dataset.done = "";
  } catch {
    // No clipboard access: select the text so ⌘C works.
    const range = document.createRange();
    range.selectNodeContents(document.getElementById("brew"));
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    copyButton.textContent = "⌘C";
  }
  setTimeout(() => { copyButton.textContent = "copy"; delete copyButton.dataset.done; }, 1800);
});

// ---- The latest release, live from GitHub ----------------------------------
// The download link never changes (releases/latest/download/Jot.zip). The
// version, date and notes come from the release itself, so publishing a
// release updates this page with no commit here.

function line(className, children) {
  const p = document.createElement("p");
  p.className = `l ${className}`.trim();
  p.append(...children);
  return p;
}

function marker(text) {
  const span = document.createElement("span");
  span.className = "mk";
  span.setAttribute("aria-hidden", "true");
  span.textContent = text;
  return span;
}

// `**bold**` and `` `code` `` in release notes, as the page's own markup.
function inline(text) {
  const nodes = [];
  const re = /\*\*([^*]+)\*\*|`([^`]+)`|\[([^\]]+)\]\([^)]+\)/g;
  let last = 0;
  for (const m of text.matchAll(re)) {
    if (m.index > last) nodes.push(document.createTextNode(text.slice(last, m.index)));
    if (m[1] !== undefined) { const b = document.createElement("b"); b.textContent = m[1]; nodes.push(b); }
    else if (m[2] !== undefined) { const c = document.createElement("code"); c.textContent = m[2]; nodes.push(c); }
    else nodes.push(document.createTextNode(m[3]));
    last = m.index + m[0].length;
  }
  if (last < text.length) nodes.push(document.createTextNode(text.slice(last)));
  return nodes;
}

function renderNotes(release) {
  const news = document.getElementById("news");
  const lines = [];
  for (const raw of (release.body || "").split(/\r?\n/)) {
    const heading = raw.match(/^##+\s+(.*)$/);
    const bullet = raw.match(/^(\s*)- (.*)$/);
    if (heading) {
      lines.push(line("", [marker("### "), ...inline(heading[1].toLowerCase())]));
    } else if (bullet) {
      // Nested bullets keep their depth: two characters per level.
      const depth = Math.min(3, Math.floor(bullet[1].replace(/\t/g, "  ").length / 2));
      const item = line(`item depth-${depth}`, [marker("- "), ...inline(bullet[2])]);
      lines.push(item);
    }
    if (lines.length >= 12) break;
  }
  if (lines.length === 0) return;
  news.replaceChildren(...lines);
}

async function loadRelease() {
  const meta = document.getElementById("version-meta");
  const newsMeta = document.getElementById("news-meta");
  const link = document.getElementById("news-link");
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!response.ok) throw new Error(String(response.status));
    const release = await response.json();
    const version = release.tag_name;
    const zip = (release.assets || []).find((a) => a.name === "Jot.zip")
      || (release.assets || []).find((a) => /^Jot-.*\.zip$/.test(a.name));
    const size = zip ? `${(zip.size / 1e6).toFixed(1)} MB` : "about 1 MB";
    meta.textContent = `${version} · ${size}`;
    // Until a release carries the fixed-name Jot.zip, link its own archive.
    if (zip && zip.name !== "Jot.zip") {
      document.querySelectorAll("[data-download]").forEach((a) => { a.href = zip.browser_download_url; });
    }
    const date = new Date(release.published_at);
    newsMeta.textContent = `${version} · ${date.toLocaleDateString("en", { month: "short", day: "numeric" }).toLowerCase()}`;
    link.href = release.html_url;
    link.textContent = `full ${version} notes on github →`;
    renderNotes(release);
  } catch {
    document.getElementById("news").replaceChildren(
      line("muted", [document.createTextNode("couldn't reach github just now. the notes are a click away.")])
    );
  }
}

loadRelease();
