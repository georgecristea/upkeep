#!/usr/bin/env node
/**
 * upkeep — keep a curated list of macOS programs on their latest version.
 * One file, zero dependencies. Node >= 22.18 runs it directly. See docs/cli-design.md.
 */
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import { homedir } from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

// ---------- types ----------
type CaskTarget = { kind: "cask"; id: string; app: string; teamId: string };
type NpmTarget = { kind: "npm"; id: string };
type FormulaTarget = { kind: "formula"; id: string };
type NativeTarget = { kind: "native"; id: string; version?: string[]; update: string[] };
type Target = CaskTarget | NpmTarget | FormulaTarget | NativeTarget;
type Manifest = { npmMinReleaseAgeHours: number; targets: Target[] };
type Status = "current" | "outdated" | "updated" | "skipped" | "failed" | "self-managed";
type Row = { id: string; kind: string; installed: string; latest: string; status: Status; note: string; app?: string; running?: boolean };
type Result = { code: number; out: string; err: string };

// ---------- constants ----------
const HOME = homedir();
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const MANIFEST = path.join(ROOT, "upkeep.json");
const LOG_DIR = path.join(HOME, "Library/Logs/upkeep");
const LOCK = path.join(HOME, ".upkeep/lock");
const PLIST = path.join(HOME, "Library/LaunchAgents/com.upkeep.plist");
const NPM_REGISTRY = "https://registry.npmjs.org/";
// Binaries are pinned to absolute paths. PATH is never trusted.
// Homebrew lives in /opt/homebrew on Apple Silicon and /usr/local on Intel.
const BREW_PREFIX = fs.existsSync("/opt/homebrew/bin/brew") ? "/opt/homebrew" : "/usr/local";
const BIN = {
  brew: `${BREW_PREFIX}/bin/brew`,
  npm: `${BREW_PREFIX}/bin/npm`,
  codesign: "/usr/bin/codesign",
  spctl: "/usr/sbin/spctl",
  plist: "/usr/libexec/PlistBuddy",
  pgrep: "/usr/bin/pgrep",
  pkill: "/usr/bin/pkill",
  open: "/usr/bin/open",
  osascript: "/usr/bin/osascript",
  launchctl: "/bin/launchctl",
};
// Where native-target commands may live (searched in order; no PATH lookup).
const NATIVE_DIRS = [path.join(HOME, ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"];
const ENV = {
  HOME,
  USER: process.env.USER ?? "",
  PATH: NATIVE_DIRS.join(":"),
  LANG: "en_US.UTF-8",
  HOMEBREW_NO_AUTO_UPDATE: "1",
  HOMEBREW_NO_ENV_HINTS: "1",
  NONINTERACTIVE: "1",
};

// ---------- cli state ----------
const argv = process.argv.slice(2);
const flags = new Set(argv.filter((a) => a.startsWith("--")));
const positional = argv.filter((a) => !a.startsWith("--"));
const command = positional.shift() ?? "help";
const FORCE = flags.has("--force");
const DRY = flags.has("--dry-run");
const JSON_OUT = flags.has("--json");
const QUIET = flags.has("--quiet");
const NO_NOTIFY = flags.has("--no-notify");
let logFile: string | null = null;

// ---------- small utilities ----------
function say(msg: string) {
  if (!QUIET && !JSON_OUT) console.log(msg);
}
/** With --json, `update` streams one JSON object per line so a UI can follow progress live. */
function emit(event: string, data: Record<string, unknown> = {}) {
  if (JSON_OUT) console.log(JSON.stringify({ event, ...data }));
}
async function notify(text: string) {
  if (NO_NOTIFY || DRY) return;
  await run(BIN.osascript, ["-e", `display notification "${text.replace(/"/g, "'")}" with title "upkeep"`], 10_000);
}
function fail(msg: string): never {
  console.error(`upkeep: ${msg}`);
  process.exit(2);
}
function log(line: string) {
  if (logFile) fs.appendFileSync(logFile, `[${new Date().toISOString()}] ${line}\n`);
}
function expandHome(s: string) {
  return s.startsWith("~/") ? path.join(HOME, s.slice(2)) : s;
}
function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}
/** Version → numeric parts. "1.2.3,45" keeps a numeric build suffix, drops a hash suffix. */
function vnum(v: string): number[] {
  const [main, extra = ""] = v.split(",");
  const s = /^\d+$/.test(extra) ? `${main}.${extra}` : main;
  return (s.match(/\d+/g) ?? []).map(Number);
}
function cmp(a: string, b: string): number {
  const x = vnum(a), y = vnum(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d) return Math.sign(d);
  }
  return 0;
}
/** Spawn without a shell, without stdin, with a fixed environment. Never prompts, never hangs. */
function run(bin: string, args: string[], timeoutMs = 20 * 60_000): Promise<Result> {
  return new Promise((resolve) => {
    const child = spawn(bin, args, { env: ENV, stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    const done = (code: number, e = err) => {
      clearTimeout(timer);
      log(`$ ${bin} ${args.join(" ")}\n  exit=${code}${out.trim() ? "\n  " + out.trim().replace(/\n/g, "\n  ") : ""}${e.trim() ? "\n  ! " + e.trim().replace(/\n/g, "\n  ! ") : ""}`);
      resolve({ code, out, err: e });
    };
    child.on("error", (e) => done(127, String(e)));
    child.on("close", (code) => done(code ?? 1));
  });
}
function resolveBin(name: string): string {
  if (path.isAbsolute(name)) return name;
  for (const d of NATIVE_DIRS) {
    const p = path.join(d, name);
    if (fs.existsSync(p)) return p;
  }
  throw new Error(`command not found in ${NATIVE_DIRS.join(":")}: ${name}`);
}
function loadManifest(): Manifest {
  // First run: start from an empty list (upkeep.example.json shows the format). Never copy the
  // example wholesale: `update` installs any listed cask that is not installed yet.
  if (!fs.existsSync(MANIFEST)) saveManifest({ npmMinReleaseAgeHours: 24, targets: [] });
  const m = JSON.parse(fs.readFileSync(MANIFEST, "utf8")) as Manifest;
  const kinds = new Set(["cask", "npm", "formula", "native"]);
  for (const t of m.targets) {
    if (!kinds.has(t.kind) || typeof t.id !== "string") fail(`bad manifest entry: ${JSON.stringify(t)}`);
    if (t.kind === "cask" && !/^[A-Z0-9]{10}$/.test(t.teamId)) fail(`bad teamId for ${t.id}`);
    if (t.kind === "native" && !Array.isArray(t.update)) fail(`native target ${t.id} needs an update argv array`);
  }
  return m;
}
function saveManifest(m: Manifest) {
  // One target per line so the file stays readable and diffable.
  const lines = m.targets.map((t) => "    " + JSON.stringify(t, null, 1).replace(/\n\s*/g, " "));
  fs.writeFileSync(MANIFEST, `{\n  "npmMinReleaseAgeHours": ${m.npmMinReleaseAgeHours},\n  "targets": [\n${lines.join(",\n")}\n  ]\n}\n`);
}

// ---------- caches filled once per run ----------
const cache = { caskInfo: new Map<string, any>(), formulaInfo: new Map<string, any>(), brewCasks: new Set<string>(), npmGlobal: new Map<string, string>() };

async function prefetch(targets: Target[]) {
  const casks = targets.filter((t) => t.kind === "cask").map((t) => t.id);
  const formulae = targets.filter((t) => t.kind === "formula").map((t) => t.id);
  const jobs: Promise<unknown>[] = [];
  if (casks.length) {
    jobs.push(run(BIN.brew, ["info", "--cask", "--json=v2", ...casks]).then((r) => {
      if (r.code) throw new Error(`brew info --cask failed: ${r.err.trim()}`);
      for (const c of JSON.parse(r.out).casks) cache.caskInfo.set(c.token, c);
    }));
    jobs.push(run(BIN.brew, ["list", "--cask", "-1"]).then((r) => r.out.split("\n").forEach((l) => l && cache.brewCasks.add(l.trim()))));
  }
  if (formulae.length) {
    jobs.push(run(BIN.brew, ["info", "--json=v2", ...formulae]).then((r) => {
      if (r.code) throw new Error(`brew info failed: ${r.err.trim()}`);
      for (const f of JSON.parse(r.out).formulae) cache.formulaInfo.set(f.name, f);
    }));
  }
  if (targets.some((t) => t.kind === "npm")) {
    jobs.push(run(BIN.npm, ["config", "get", "registry"]).then((r) => {
      if (r.out.trim() !== NPM_REGISTRY) throw new Error(`npm registry is ${r.out.trim()}, expected ${NPM_REGISTRY}`);
    }));
    jobs.push(run(BIN.npm, ["ls", "-g", "--json", "--depth=0"]).then((r) => {
      const deps = JSON.parse(r.out || "{}").dependencies ?? {};
      for (const [k, v] of Object.entries<any>(deps)) cache.npmGlobal.set(k, v.version);
    }));
  }
  await Promise.all(jobs);
}

// ---------- cask adapter ----------
const appPath = (t: CaskTarget) => path.join("/Applications", t.app);
async function plistValue(t: CaskTarget, key: string) {
  const r = await run(BIN.plist, ["-c", `Print ${key}`, path.join(appPath(t), "Contents/Info.plist")]);
  return r.code ? null : r.out.trim();
}
async function isRunning(t: CaskTarget) {
  // Any process living inside the bundle (main binary or helpers) counts as running.
  const r = await run(BIN.pgrep, ["-f", `^${appPath(t)}/`]);
  return r.code === 0;
}
async function quitApp(t: CaskTarget) {
  const bundleId = await plistValue(t, "CFBundleIdentifier");
  if (bundleId) await run(BIN.osascript, ["-e", `tell application id "${bundleId}" to quit`], 20_000);
  for (let i = 0; i < 30 && (await isRunning(t)); i++) await sleep(500);
  if (await isRunning(t)) {
    await run(BIN.pkill, ["-f", `^${appPath(t)}/`]);
    await sleep(1000);
  }
  if (await isRunning(t)) throw new Error(`could not quit ${t.app}`);
}
async function verifyApp(t: CaskTarget) {
  const app = appPath(t);
  const a = await run(BIN.codesign, ["--verify", "--deep", "--strict", app]);
  if (a.code) throw new Error(`codesign verify failed: ${a.err.trim()}`);
  const b = await run(BIN.codesign, ["-dv", app]);
  const team = /TeamIdentifier=(\S+)/.exec(b.err)?.[1];
  if (team !== t.teamId) throw new Error(`Team ID mismatch: expected ${t.teamId}, got ${team ?? "none"}`);
  const c = await run(BIN.spctl, ["--assess", "--type", "execute", app]);
  if (c.code) throw new Error(`Gatekeeper rejected the app: ${c.err.trim()}`);
}
const cask = {
  installed: (t: CaskTarget) => plistValue(t, "CFBundleShortVersionString"),
  // Cask versions may carry ",<hash>"; keep a numeric build suffix, drop a hash.
  latest: async (t: CaskTarget) => (cache.caskInfo.get(t.id)?.version as string | undefined)?.replace(/,(?!\d+$).*$/, "") ?? null,
  async update(t: CaskTarget) {
    // Managed: normal upgrade. Unmanaged (first time): a force install replaces the app with the cask's copy
    // and Homebrew manages it from then on. (Homebrew's --adopt is avoided: it chmods the existing bundle,
    // which macOS App Management protection can refuse.)
    const r = cache.brewCasks.has(t.id)
      ? await run(BIN.brew, ["upgrade", "--cask", "--greedy", t.id])
      : await run(BIN.brew, ["install", "--cask", "--force", t.id]);
    if (r.code) throw new Error(`brew failed: ${(r.err || r.out).trim().split("\n").at(-1)}`);
    await verifyApp(t);
  },
};

// ---------- npm adapter ----------
const npm = {
  installed: async (t: NpmTarget) => cache.npmGlobal.get(t.id) ?? null,
  async latest(t: NpmTarget, minAgeHours: number) {
    const r = await run(BIN.npm, ["view", t.id, "version", "time", "--json"]);
    if (r.code) throw new Error(`npm view failed: ${r.err.trim()}`);
    const { version: tag, time } = JSON.parse(r.out) as { version: string; time: Record<string, string> };
    if (minAgeHours <= 0) return tag;
    const cutoff = Date.now() - minAgeHours * 3_600_000;
    const ok = Object.entries(time)
      .filter(([v, at]) => /^\d+\.\d+\.\d+$/.test(v) && Date.parse(at) <= cutoff && cmp(v, tag) <= 0)
      .map(([v]) => v)
      .sort(cmp);
    return ok.at(-1) ?? null;
  },
  async update(t: NpmTarget, version: string) {
    const r = await run(BIN.npm, ["install", "-g", `${t.id}@${version}`]);
    if (r.code) throw new Error(`npm install failed: ${r.err.trim().split("\n").at(-1)}`);
  },
};

// ---------- formula adapter ----------
const formula = {
  installed: async (t: FormulaTarget) => {
    const r = await run(BIN.brew, ["list", "--versions", t.id]);
    return r.code ? null : r.out.trim().split(/\s+/).at(-1) ?? null;
  },
  latest: async (t: FormulaTarget) => (cache.formulaInfo.get(t.id)?.versions?.stable as string | undefined) ?? null,
  async update(t: FormulaTarget) {
    const r = await run(BIN.brew, ["upgrade", t.id]);
    if (r.code) throw new Error(`brew upgrade failed: ${r.err.trim().split("\n").at(-1)}`);
  },
};

// ---------- native adapter (tools that update themselves) ----------
const native = {
  async installed(t: NativeTarget) {
    if (!t.version) return null;
    const [bin, ...args] = t.version.map(expandHome);
    const r = await run(resolveBin(bin), args, 60_000);
    if (r.code) return null;
    const line = r.out.trim().split("\n")[0] ?? "";
    return /\d+\.\d+[\w.+-]*/.exec(line)?.[0] ?? line;
  },
  async update(t: NativeTarget) {
    const [bin, ...args] = t.update.map(expandHome);
    const r = await run(resolveBin(bin), args);
    if (r.code) throw new Error(`${bin} failed: ${(r.err || r.out).trim().split("\n").at(-1)}`);
  },
};

// ---------- the two main commands ----------
async function inspect(t: Target, m: Manifest): Promise<Row> {
  const row: Row = { id: t.id, kind: t.kind, installed: "-", latest: "-", status: "current", note: "" };
  if (t.kind === "cask") {
    row.app = t.app; // lets a UI show the real app icon
    row.running = await isRunning(t); // and offer "quit & update" up front
  }
  try {
    if (t.kind === "native") {
      row.installed = (await native.installed(t)) ?? "-";
      row.latest = "-";
      row.status = "self-managed";
      return row;
    }
    const installed = t.kind === "cask" ? await cask.installed(t) : t.kind === "npm" ? await npm.installed(t) : await formula.installed(t);
    const latest = t.kind === "cask" ? await cask.latest(t) : t.kind === "npm" ? await npm.latest(t, m.npmMinReleaseAgeHours) : await formula.latest(t);
    row.installed = installed ?? "-";
    row.latest = latest ?? "-";
    if (!latest) {
      row.status = "current";
      row.note = t.kind === "npm" ? `no release older than ${m.npmMinReleaseAgeHours}h` : "latest unknown";
    } else if (!installed) {
      row.status = "outdated";
      row.note = "not installed";
    } else if (cmp(installed, latest) < 0) {
      row.status = "outdated";
    } else if (t.kind === "cask" && !cache.brewCasks.has(t.id)) {
      row.status = "outdated";
      row.note = "not yet managed by Homebrew (will reinstall from cask)";
    }
  } catch (e) {
    row.status = "failed";
    row.note = (e as Error).message;
  }
  return row;
}

async function applyUpdate(t: Target, row: Row, reopen: CaskTarget[]): Promise<Row> {
  if (t.kind === "native") {
    if (DRY) return { ...row, note: "would run updater" };
    await native.update(t);
    const after = (await native.installed(t)) ?? "-";
    return { ...row, latest: after, status: after !== row.installed ? "updated" : "current" };
  }
  if (row.status !== "outdated") return row;
  if (t.kind === "cask") {
    const running = await isRunning(t);
    if (running && !FORCE) return { ...row, status: "skipped", note: "running; use --force" };
    if (DRY) return { ...row, note: running ? "would quit, update, reopen" : "would update" };
    if (running) {
      await quitApp(t);
      reopen.push(t);
    }
    await cask.update(t);
    return { ...row, installed: (await cask.installed(t)) ?? "-", status: "updated", note: "signature verified" };
  }
  if (DRY) return { ...row, note: "would update" };
  if (t.kind === "npm") await npm.update(t, row.latest);
  else await formula.update(t);
  return { ...row, installed: row.latest, status: "updated", note: "" };
}

function printRows(rows: Row[]) {
  if (JSON_OUT) return console.log(JSON.stringify(rows, null, 2));
  const w = (k: keyof Row) => Math.max(k.length, ...rows.map((r) => String(r[k]).length));
  const cols: (keyof Row)[] = ["id", "kind", "installed", "latest", "status"];
  const line = (r: Record<string, string>) => cols.map((c) => String(r[c]).padEnd(w(c))).join("  ") + (r.note ? `  ${r.note}` : "");
  console.log(line({ id: "ID", kind: "KIND", installed: "INSTALLED", latest: "LATEST", status: "STATUS", note: "" }));
  for (const r of rows) console.log(line(r as unknown as Record<string, string>));
}

function selectTargets(m: Manifest): Target[] {
  if (!positional.length) return m.targets;
  const byId = new Map(m.targets.map((t) => [t.id, t]));
  return positional.map((id) => byId.get(id) ?? fail(`not in manifest: ${id}`));
}

async function refreshBrew(m: Manifest) {
  if (!m.targets.some((t) => t.kind === "cask" || t.kind === "formula")) return;
  say("refreshing Homebrew index...");
  const r = await run(BIN.brew, ["update", "--quiet"], 5 * 60_000);
  if (r.code) throw new Error(`brew update failed: ${r.err.trim()}`);
}

async function cmdCheck() {
  const m = loadManifest();
  const targets = selectTargets(m);
  await refreshBrew(m);
  await prefetch(targets);
  const rows = await Promise.all(targets.map((t) => inspect(t, m)));
  printRows(rows);
  process.exit(rows.some((r) => r.status === "outdated" || r.status === "failed") ? 1 : 0);
}

async function cmdUpdate() {
  const m = loadManifest();
  const targets = selectTargets(m);
  acquireLock();
  fs.mkdirSync(LOG_DIR, { recursive: true });
  logFile = path.join(LOG_DIR, new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19) + ".log");
  log(`upkeep update ${argv.join(" ")}`);
  const rows: Row[] = [];
  const reopen: CaskTarget[] = [];
  let fatal: Error | null = null;
  // Casks last: they may quit apps. Everything else first.
  const ordered = [...targets.filter((t) => t.kind !== "cask"), ...targets.filter((t) => t.kind === "cask")];
  emit("start", { targets: ordered.map((t) => t.id), dryRun: DRY, force: FORCE, log: logFile });
  try {
    await refreshBrew(m);
    await prefetch(targets);
    for (const t of ordered) {
      const before = await inspect(t, m);
      let row = before;
      if (before.status === "outdated" || before.status === "self-managed") {
        say(`${DRY ? "checking" : "updating"} ${t.id}...`);
        emit("updating", { id: t.id });
        try {
          row = await applyUpdate(t, before, reopen);
        } catch (e) {
          row = { ...before, status: "failed", note: (e as Error).message };
        }
      }
      rows.push(row);
      emit("result", row);
      log(`${row.id}: ${row.status} ${before.installed} -> ${row.installed} ${row.note}`);
    }
  } catch (e) {
    fatal = e as Error;
  } finally {
    for (const t of reopen) {
      say(`reopening ${t.app}...`);
      await run(BIN.open, ["-g", "-a", appPath(t)]);
    }
  }
  if (fatal) {
    log(`FATAL: ${fatal.message}`);
    emit("fatal", { message: fatal.message, log: logFile });
    await notify(`FAILED: ${fatal.message}`);
    fail(fatal.message);
  }
  const n = (s: Status) => rows.filter((r) => r.status === s).length;
  const summary = `${n("updated")} updated, ${n("skipped")} skipped, ${n("failed")} failed`;
  if (JSON_OUT) {
    emit("done", { updated: n("updated"), skipped: n("skipped"), failed: n("failed"), rows, log: logFile });
  } else {
    printRows(rows);
    say(`\n${summary}${logFile ? `\nlog: ${logFile}` : ""}`);
  }
  const failed = rows.filter((r) => r.status === "failed").map((r) => r.id);
  await notify(failed.length ? `FAILED: ${failed.join(", ")}` : summary);
  process.exit(n("failed") ? 1 : 0);
}

function acquireLock() {
  fs.mkdirSync(path.dirname(LOCK), { recursive: true });
  try {
    fs.writeFileSync(LOCK, String(process.pid), { flag: "wx" });
  } catch {
    const pid = Number(fs.readFileSync(LOCK, "utf8"));
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch { /* stale */ }
    if (alive) fail(`another upkeep run is active (pid ${pid})`);
    fs.writeFileSync(LOCK, String(process.pid));
  }
  process.on("exit", () => { try { fs.unlinkSync(LOCK); } catch { /* ignore */ } });
}

// ---------- manifest editing ----------
async function cmdAdd() {
  const id = positional[0] ?? fail("usage: upkeep add <id>");
  const m = loadManifest();
  if (m.targets.some((t) => t.id === id)) fail(`${id} is already in the manifest`);
  let target: Target | null = null;
  // A name can exist both on npm and in Homebrew (e.g. "gh"). Whatever is already installed wins.
  const [formulae, globals] = await Promise.all([run(BIN.brew, ["list", "--formula", "-1"]), run(BIN.npm, ["ls", "-g", "--json", "--depth=0"])]);
  const installedFormula = formulae.out.split("\n").map((l) => l.trim()).includes(id);
  const installedNpm = id in (JSON.parse(globals.out || "{}").dependencies ?? {});
  const c = installedFormula || installedNpm ? { code: 1, out: "" } : await run(BIN.brew, ["info", "--cask", "--json=v2", id]);
  if (installedFormula) {
    target = { kind: "formula", id };
  } else if (installedNpm) {
    target = { kind: "npm", id };
  } else if (c.code === 0) {
    const info = JSON.parse(c.out).casks[0];
    if (info.artifacts.some((a: any) => a.pkg || a.installer)) fail(`${id} uses a .pkg installer, which may need sudo; not supported`);
    const app = info.artifacts.find((a: any) => a.app)?.app?.[0] ?? fail(`${id} does not install an .app`);
    const t: CaskTarget = { kind: "cask", id, app, teamId: "" };
    if (!fs.existsSync(appPath(t))) fail(`${app} is not installed; run: brew install --cask ${id}  then add it again`);
    const sig = await run(BIN.codesign, ["-dv", appPath(t)]);
    t.teamId = /TeamIdentifier=(\S+)/.exec(sig.err)?.[1] ?? fail(`${app} has no Team ID; refusing to add an unsigned app`);
    target = t;
  } else if ((await run(BIN.npm, ["view", id, "version"])).code === 0) {
    target = { kind: "npm", id };
  } else if ((await run(BIN.brew, ["info", "--json=v2", id])).code === 0) {
    target = { kind: "formula", id };
  }
  if (!target) fail(`${id} is not a Homebrew cask, npm package, or Homebrew formula. For self-updating tools, add a "native" entry to upkeep.json by hand.`);
  m.targets.push(target);
  saveManifest(m);
  say(`added ${JSON.stringify(target)}`);
}
function cmdRemove() {
  const id = positional[0] ?? fail("usage: upkeep remove <id>");
  const m = loadManifest();
  const n = m.targets.length;
  m.targets = m.targets.filter((t) => t.id !== id);
  if (m.targets.length === n) fail(`not in manifest: ${id}`);
  saveManifest(m);
  say(`removed ${id}`);
}
function cmdList() {
  const m = loadManifest();
  if (JSON_OUT) return console.log(JSON.stringify(m, null, 2));
  if (!m.targets.length) return say(`nothing tracked yet: add a program with \`upkeep add <id>\` (manifest: ${MANIFEST})`);
  for (const t of m.targets) console.log(`${t.kind.padEnd(8)} ${t.id}${t.kind === "cask" ? `  (${t.app}, ${t.teamId})` : ""}`);
}

// ---------- scheduling (launchd) ----------
async function cmdSchedule() {
  const sub = positional[0] ?? "status";
  const uid = process.getuid!();
  if (sub === "install") {
    const at = (argv.find((a) => a.startsWith("--at="))?.slice(5) ?? "04:00").split(":").map(Number);
    const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.upkeep</string>
  <key>ProgramArguments</key><array>
    <string>${process.execPath}</string><string>${path.join(ROOT, "upkeep.ts")}</string>
    <string>update</string><string>--force</string><string>--quiet</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>${at[0]}</integer><key>Minute</key><integer>${at[1] ?? 0}</integer></dict>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>${ENV.PATH}</string><key>HOME</key><string>${HOME}</string></dict>
  <key>StandardOutPath</key><string>${path.join(LOG_DIR, "launchd.out.log")}</string>
  <key>StandardErrorPath</key><string>${path.join(LOG_DIR, "launchd.err.log")}</string>
</dict></plist>
`;
    fs.mkdirSync(path.dirname(PLIST), { recursive: true });
    fs.mkdirSync(LOG_DIR, { recursive: true });
    await run(BIN.launchctl, ["bootout", `gui/${uid}/com.upkeep`]);
    fs.writeFileSync(PLIST, plist);
    const r = await run(BIN.launchctl, ["bootstrap", `gui/${uid}`, PLIST]);
    if (r.code) fail(`launchctl bootstrap failed: ${r.err.trim()}`);
    say(`scheduled daily at ${String(at[0]).padStart(2, "0")}:${String(at[1] ?? 0).padStart(2, "0")} (${PLIST})`);
  } else if (sub === "remove") {
    await run(BIN.launchctl, ["bootout", `gui/${uid}/com.upkeep`]);
    if (fs.existsSync(PLIST)) fs.unlinkSync(PLIST);
    say("schedule removed");
  } else {
    const r = await run(BIN.launchctl, ["print", `gui/${uid}/com.upkeep`]);
    say(r.code ? "not scheduled" : `scheduled (${PLIST})`);
  }
}

function cmdLog() {
  process.stdout.on("error", () => process.exit(0)); // `upkeep log | head` closes the pipe early
  if (!fs.existsSync(LOG_DIR)) fail("no logs yet");
  const latest = fs.readdirSync(LOG_DIR).filter((f) => /^\d{4}-/.test(f)).sort().at(-1) ?? fail("no logs yet");
  process.stdout.write(fs.readFileSync(path.join(LOG_DIR, latest), "utf8"));
}

function help() {
  console.log(`upkeep — keep your core programs current

  upkeep check [id...]         show installed vs latest (exit 1 if anything is outdated)
  upkeep update [id...]        update outdated targets; running apps are skipped unless --force
  upkeep add <id>              add a Homebrew cask, npm package, or formula to upkeep.json
  upkeep remove <id>
  upkeep list
  upkeep schedule install [--at=HH:MM] | remove | status
  upkeep log                   print the latest update log

  flags: --force  --dry-run  --json  --quiet  --no-notify
  (update --json streams one JSON event per line: start, updating, result, done | fatal)
  manifest: ${MANIFEST}`);
}

const commands: Record<string, () => unknown> = { check: cmdCheck, update: cmdUpdate, add: cmdAdd, remove: cmdRemove, list: cmdList, schedule: cmdSchedule, log: cmdLog, help, "--help": help };
Promise.resolve((commands[command] ?? (() => fail(`unknown command: ${command} (try: upkeep help)`)))()).catch((e) => fail((e as Error).message));
