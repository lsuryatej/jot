// A small cousin of Jot's own evaluator, for the scratchpad on this page.
// Same rules where it matters: the note is read top to bottom, `name = value`
// is visible below it, a line with no operator stays prose ("5 apples"), and
// results only ever go in the margin. Units and currencies are a short list;
// the app has the full table.

const UNITS = {
  // length, in metres
  mm: ["length", 0.001, "mm"], cm: ["length", 0.01, "cm"], m: ["length", 1, "m"],
  km: ["length", 1000, "km"], in: ["length", 0.0254, "in"], inch: ["length", 0.0254, "in"],
  inches: ["length", 0.0254, "in"], ft: ["length", 0.3048, "ft"], feet: ["length", 0.3048, "ft"],
  foot: ["length", 0.3048, "ft"], yd: ["length", 0.9144, "yd"], mi: ["length", 1609.344, "mi"],
  mile: ["length", 1609.344, "mi"], miles: ["length", 1609.344, "mi"],
  kilometers: ["length", 1000, "km"], kilometres: ["length", 1000, "km"],
  meters: ["length", 1, "m"], metres: ["length", 1, "m"],
  // mass, in kilograms
  g: ["mass", 0.001, "g"], kg: ["mass", 1, "kg"], oz: ["mass", 0.028349523125, "oz"],
  lb: ["mass", 0.45359237, "lb"], lbs: ["mass", 0.45359237, "lb"], pounds: ["mass", 0.45359237, "lb"],
  kilograms: ["mass", 1, "kg"], grams: ["mass", 0.001, "g"],
  // time, in seconds
  s: ["time", 1, "s"], sec: ["time", 1, "s"], min: ["time", 60, "min"], mins: ["time", 60, "min"],
  minutes: ["time", 60, "min"], h: ["time", 3600, "h"], hr: ["time", 3600, "h"], hours: ["time", 3600, "h"],
  day: ["time", 86400, "day"], days: ["time", 86400, "day"], week: ["time", 604800, "week"], weeks: ["time", 604800, "week"],
  // data, in bytes
  b: ["data", 1, "B"], kb: ["data", 1e3, "KB"], mb: ["data", 1e6, "MB"], gb: ["data", 1e9, "GB"],
  // currency, in US dollars: a fixed snapshot, like the app with live rates off
  usd: ["money", 1, "usd"], eur: ["money", 1.08, "eur"], gbp: ["money", 1.27, "gbp"],
  inr: ["money", 0.0114, "inr"], jpy: ["money", 0.0067, "jpy"], cad: ["money", 0.73, "cad"],
  aud: ["money", 0.66, "aud"],
  // temperature, converted specially
  c: ["temp", 0, "°C"], f: ["temp", 0, "°F"], k: ["temp", 0, "K"],
  celsius: ["temp", 0, "°C"], fahrenheit: ["temp", 0, "°F"],
};

const TEMP_KEY = { "°C": "c", "°F": "f", "K": "k" };

function toKelvin(n, name) {
  if (name === "°C") return n + 273.15;
  if (name === "°F") return (n - 32) * 5 / 9 + 273.15;
  return n;
}
function fromKelvin(n, name) {
  if (name === "°C") return n - 273.15;
  if (name === "°F") return (n - 273.15) * 9 / 5 + 32;
  return n;
}

function unitFor(word) {
  const u = UNITS[word.toLowerCase()];
  return u ? { dim: u[0], factor: u[1], name: u[2] } : null;
}

function convert(value, target) {
  if (!value.unit) return { n: value.n, unit: target, pct: false };
  if (value.unit.dim !== target.dim) throw new Error("units");
  if (target.dim === "temp") {
    return { n: fromKelvin(toKelvin(value.n, value.unit.name), target.name), unit: target, pct: false };
  }
  return { n: value.n * value.unit.factor / target.factor, unit: target, pct: false };
}

// Tokens: numbers (with thousands separators), words, and symbols.
function tokenize(line) {
  const tokens = [];
  const re = /\s*(?:(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+)|([A-Za-z_][A-Za-z0-9_]*)|(°[CF]|[-+*/^()%$=×÷]))/y;
  let i = 0;
  while (i < line.length) {
    re.lastIndex = i;
    const m = re.exec(line);
    if (!m) {
      if (/\s/.test(line.slice(i))) break;
      return null; // something this evaluator doesn't read: leave the line alone
    }
    if (m[1] !== undefined) tokens.push({ t: "num", v: parseFloat(m[1].replace(/,/g, "")) });
    else if (m[2] !== undefined) tokens.push({ t: "word", v: m[2] });
    else tokens.push({ t: "sym", v: m[3] === "×" ? "*" : m[3] === "÷" ? "/" : m[3] });
    i = re.lastIndex;
  }
  return tokens;
}

class Parser {
  constructor(tokens, vars) { this.tokens = tokens; this.i = 0; this.vars = vars; this.sawOperator = false; }
  peek() { return this.tokens[this.i]; }
  next() { return this.tokens[this.i++]; }
  isSym(v) { const t = this.peek(); return t && t.t === "sym" && t.v === v; }
  isWord(...vs) { const t = this.peek(); return t && t.t === "word" && vs.includes(t.v.toLowerCase()); }

  parseLine() {
    const value = this.conversion();
    if (this.i !== this.tokens.length) throw new Error("trailing");
    return value;
  }

  conversion() {
    let value = this.additive();
    if (this.isWord("to", "in", "as")) {
      this.next();
      const t = this.next();
      const target = t && (t.t === "word" ? unitFor(t.v) : t.t === "sym" && TEMP_KEY[t.v] !== undefined ? unitFor(TEMP_KEY[t.v]) : null);
      if (!target) throw new Error("unit");
      this.sawOperator = true;
      value = convert(value, target);
    }
    return value;
  }

  additive() {
    let left = this.multiplicative();
    for (;;) {
      let op = null;
      if (this.isSym("+") || this.isWord("plus")) op = "+";
      else if (this.isSym("-") || this.isWord("minus")) op = "-";
      if (!op) return left;
      this.next();
      this.sawOperator = true;
      const right = this.multiplicative();
      if (right.pct && !left.pct) {
        // 50 + 20% is 60: a percentage of the left side
        const factor = op === "+" ? 1 + right.n / 100 : 1 - right.n / 100;
        left = { n: left.n * factor, unit: left.unit, pct: false };
      } else {
        const r = left.unit && right.unit && left.unit.name !== right.unit.name ? convert(right, left.unit) : right;
        left = { n: op === "+" ? left.n + r.n : left.n - r.n, unit: left.unit || r.unit, pct: left.pct && r.pct };
      }
    }
  }

  multiplicative() {
    let left = this.power();
    for (;;) {
      let op = null;
      if (this.isSym("*") || this.isWord("x", "times")) op = "*";
      else if (this.isSym("/")) op = "/";
      if (!op) return left;
      this.next();
      this.sawOperator = true;
      const right = this.power();
      const l = left.pct ? left.n / 100 : left.n;
      const r = right.pct ? right.n / 100 : right.n;
      if (op === "/" && r === 0) throw new Error("divide");
      left = { n: op === "*" ? l * r : l / r, unit: left.unit || right.unit, pct: false };
    }
  }

  power() {
    const base = this.unary();
    if (this.isSym("^")) {
      this.next();
      this.sawOperator = true;
      const exponent = this.unary();
      return { n: Math.pow(base.n, exponent.n), unit: base.unit, pct: false };
    }
    return base;
  }

  unary() {
    if (this.isSym("-")) {
      this.next();
      const v = this.unary();
      return { n: -v.n, unit: v.unit, pct: v.pct };
    }
    return this.percentage();
  }

  // 20% of 50, 20% on 50, 20% off 50
  percentage() {
    const value = this.postfix();
    if (value.pct && this.isWord("of", "on", "off")) {
      const word = this.next().v.toLowerCase();
      this.sawOperator = true;
      const base = this.postfix();
      const p = value.n / 100;
      const n = word === "of" ? base.n * p : word === "on" ? base.n * (1 + p) : base.n * (1 - p);
      return { n, unit: base.unit, pct: false };
    }
    return value;
  }

  postfix() {
    const value = this.primary();
    if (this.isSym("%")) {
      this.next();
      this.sawOperator = true;
      return { n: value.n, unit: null, pct: true };
    }
    const t = this.peek();
    if (t && t.t === "word" && !value.unit) {
      const unit = unitFor(t.v);
      if (unit && !["in"].includes(t.v.toLowerCase())) {
        this.next();
        return { n: value.n, unit, pct: false };
      }
    }
    if (t && t.t === "sym" && TEMP_KEY[t.v] !== undefined && !value.unit) {
      this.next();
      return { n: value.n, unit: unitFor(TEMP_KEY[t.v]), pct: false };
    }
    return value;
  }

  primary() {
    const t = this.next();
    if (!t) throw new Error("end");
    if (t.t === "num") return { n: t.v, unit: null, pct: false };
    if (t.t === "sym" && t.v === "$") {
      const n = this.next();
      if (!n || n.t !== "num") throw new Error("dollar");
      return { n: n.v, unit: unitFor("usd"), pct: false };
    }
    if (t.t === "sym" && t.v === "(") {
      const v = this.additive();
      if (!this.isSym(")")) throw new Error("paren");
      this.next();
      return v;
    }
    if (t.t === "word") {
      const key = t.v.toLowerCase();
      if (key in this.vars) return { ...this.vars[key] };
    }
    throw new Error("token");
  }
}

function format(value) {
  let n = value.n;
  if (!isFinite(n)) return null;
  const rounded = Math.round(n * 1e4) / 1e4;
  let text = Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
  if (value.unit) {
    if (value.unit.dim === "money") text = (Math.round(n * 100) / 100).toFixed(2).replace(/\.00$/, "") + " " + value.unit.name;
    else text += value.unit.name.startsWith("°") ? value.unit.name : " " + value.unit.name;
  }
  if (value.pct) text += "%";
  return text;
}

// Evaluates a whole note. Returns one result (or null) per line.
export function evaluateNote(text) {
  const vars = {};
  return text.split("\n").map((raw) => {
    const line = raw.replace(/\/\/.*$/, "").trim();
    if (!line || /^(#|- |\* |\[)/.test(line)) return null;
    let label = null;
    let expression = line;
    const assignment = line.match(/^([A-Za-z_][A-Za-z0-9_ ]*?)\s*=\s*(.+)$/);
    if (assignment) {
      label = assignment[1].trim().toLowerCase().replace(/\s+/g, "_");
      expression = assignment[2];
    }
    const tokens = tokenize(expression);
    if (!tokens || tokens.length === 0) return null;
    // A lone variable shows its value.
    if (!assignment && tokens.length === 1 && tokens[0].t === "word" && tokens[0].v.toLowerCase() in vars) {
      return format(vars[tokens[0].v.toLowerCase()]);
    }
    try {
      const parser = new Parser(tokens, vars);
      const value = parser.parseLine();
      if (assignment) {
        vars[label] = value;
        // As in the app, an assignment shows its value in the margin.
        return format(value);
      }
      // Prose stays prose: "5 apples" has no operator, so no result.
      if (!parser.sawOperator) return null;
      return format(value);
    } catch {
      return null;
    }
  });
}
