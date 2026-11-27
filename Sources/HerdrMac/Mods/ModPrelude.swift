/// The JavaScript every mod context starts with: "gpui-kit lite" (elements that record
/// their builder calls into a tree SwiftUI draws), `cx`, a module loader, and the `herdr`
/// API, forwarding to Swift through `__host`.
enum ModPrelude {
    static let source = #"""
(function () {
  "use strict";
  const H = globalThis.__host;
  globalThis.console = { log: (...a) => H.log(a.map(String).join(" ")), warn: (...a) => H.log("warn: " + a.map(String).join(" ")), error: (...a) => H.log("error: " + a.map(String).join(" ")) };

  // ---- Elements: every builder call is recorded; the host interprets the ones it knows.
  let clicks = [];
  const EL = Symbol("el");
  function element(kind, arg) {
    // Internal fields start with "_": every other name is a builder method.
    const target = { [EL]: true, _kind: kind, _arg: arg, _calls: [], _kids: [], _click: null, _hover: null };
    const proxy = new Proxy(target, {
      get(t, p) {
        if (typeof p === "symbol") return t[p];
        if (p === "then") return undefined; // never mistaken for a promise
        if (p.startsWith("_") && p in t) return t[p];
        if (p in methods) return methods[p].bind(null, t, proxy);
        return (...a) => { t._calls.push([p, a]); return proxy; };
      },
    });
    return proxy;
  }
  function add(kids, x) {
    if (x == null || x === false || x === true) return;
    if (Array.isArray(x)) { for (const y of x) add(kids, y); return; }
    kids.push(x);
  }
  function recorder() {
    const calls = [];
    const p = new Proxy({}, { get: (_, name) => typeof name === "symbol" ? undefined : (...a) => { calls.push([name, a]); return p; } });
    return { p, calls };
  }
  const methods = {
    child: (t, p, x) => { add(t._kids, x); return p; },
    children: (t, p, xs) => { for (const x of (xs ?? [])) add(t._kids, x); return p; },
    when: (t, p, c, f) => (c ? (f(p) ?? p) : p),
    when_some: (t, p, v, f) => (v != null ? (f(p, v) ?? p) : p),
    map: (t, p, f) => f(p) ?? p,
    on_click: (t, p, f) => { t._click = f; return p; },
    on_mouse_down: (t, p, button, f) => { if (button === "left" && !t._click) t._click = f; return p; },
    on_mouse_up: (t, p) => p,
    hover: (t, p, f) => { const r = recorder(); f(r.p); t._hover = r.calls; return p; },
    active: (t, p) => p,
    track_focus: (t, p) => p, on_key_down: (t, p) => p, on_scroll_wheel: (t, p) => p, on_hover: (t, p) => p,
    on_size_change: (t, p) => p, on_drop: (t, p) => p, drag_paths: (t, p) => p, track_scroll: (t, p) => p,
    tooltip: (t, p, text) => { if (typeof text === "string") t._calls.push(["tooltip", [text]]); return p; },
  };
  function plain(v) {
    if (v == null || typeof v === "function") return null;
    if (typeof v === "object" && !Array.isArray(v)) { const o = {}; for (const k of Object.keys(v)) o[k] = plain(v[k]); return o; }
    return Array.isArray(v) ? v.map(plain) : v;
  }
  function tree(x) {
    if (typeof x === "string" || typeof x === "number") return { t: String(x) };
    if (!x || !x[EL]) return { t: String(x) };
    const node = { k: x._kind, a: x._arg ?? null, s: x._calls.map(([n, a]) => [n, a.map(plain)]), c: x._kids.map(tree) };
    if (x._hover) node.h = x._hover.map(([n, a]) => [n, a.map(plain)]);
    if (x._click) { node.on = clicks.length; clicks.push(x._click); }
    return node;
  }

  // ---- The view: an instance of the mod's default export.
  let instance = null, Klass = null, cxObj = null;
  function cx() {
    if (cxObj) return cxObj;
    cxObj = {
      notify: () => H.notify(),
      // gpui-kit's Task: is_done() once the work has finished (or failed); cancel() stops
      // caring about it (JavaScript can't stop a running async function).
      spawn: (f) => {
        const task = { done: false, cancelled: false, is_done() { return this.done; }, cancel() { this.cancelled = true; this.done = true; } };
        Promise.resolve().then(() => f(cx())).catch((e) => H.log("task failed: " + (e?.stack ?? e))).finally(() => { task.done = true; });
        return task;
      },
      sleep: (ms) => new Promise((r) => H.after(ms, r)),
      timer: { every: (ms, f) => H.every(ms, () => f(cx())), after: (ms, f) => H.after(ms, () => f(cx())) },
      stop_propagation() {}, prevent_default() {},
      focus_handle: () => ({ focus() {}, blur() {}, is_focused: () => false }),
      refresh() { H.notify(); },
    };
    return cxObj;
  }
  globalThis.__start = (modulePath, propsJSON) => {
    const ex = load(modulePath);
    Klass = ex.default;
    if (typeof Klass !== "function") throw new Error("main.js has no default export class");
    instance = new Klass();
    instance.init?.(JSON.parse(propsJSON), cx());
  };
  globalThis.__render = () => {
    clicks = [];
    return JSON.stringify(tree(instance.render(cx())));
  };
  globalThis.__click = (id) => { const f = clicks[id]; if (f) f({ position: { x: 0, y: 0 }, click_count: 1 }, cx()); };
  globalThis.__close = () => instance?.close?.(cx());

  // ---- Modules.
  class View {}
  class ScrollHandle { static new() { return new ScrollHandle(); } scroll_to_item() {} offset() { return { x: 0, y: 0 }; } content_size() { return { width: 0, height: 0 }; } viewport_size() { return { width: 0, height: 0 }; } }
  const kit = {
    View, div: () => element("div"), svg: (path) => element("svg", path), img: (path) => element("image", path), image: (path) => element("image", path),
    list: () => element("v"), uniform_list: () => element("v"),
  };
  // Text fields: the state lives here, the field in SwiftUI; edits come back via __input.
  const inputs = {};
  let nextInput = 1;
  class InputState {
    static new(o) { return new InputState(o); }
    constructor(o) { this._id = nextInput++; this._value = String(o?.value ?? ""); this._placeholder = o?.placeholder ?? ""; this._handlers = {}; inputs[this._id] = this; }
    on(event, f) { (this._handlers[event] ??= []).push(f); return this; }
    value() { return this._value; }
    set_value(v) { this._value = String(v ?? ""); H.notify(); return this; }
    set_placeholder(p) { this._placeholder = String(p ?? ""); return this; }
    focus() { return this; } blur() { return this; } release() { delete inputs[this._id]; } select_all() { return this; }
  }
  const Input = { new: (state) => { const el = element("input"); el.__input(state._id, state._placeholder, state._value); return el; } };
  globalThis.__input = (id, event, value) => {
    const s = inputs[id];
    if (!s) return;
    if (event === "change") s._value = value;
    for (const f of s._handlers[event] ?? []) f({ value: s._value }, cx());
  };
  // Virtual lists: their rows (up to 10,000) in a lazy SwiftUI scroll list, which draws
  // only what's visible.
  const virtualList = (kind) => (id, count, _size, _key, renderRange) => {
    const el = element(kind);
    if (typeof renderRange === "function") el.children(renderRange({ start: 0, end: Math.min(Number(count) || 0, 10000) }) ?? []);
    return el;
  };
  // Scrollbars: SwiftUI's scroll areas have their own.
  const scrollbar = () => element("none");
  const base = {
    v_flex: () => element("v"), h_flex: () => element("h"), ScrollHandle, InputState, Input,
    v_virtual_list: virtualList("vlist"), h_virtual_list: virtualList("h"),
    Button: { new: () => element("div") }, Scrollbar: { new: scrollbar, vertical: scrollbar, horizontal: scrollbar, both: scrollbar },
  };
  const parse = (s) => (s == null ? null : JSON.parse(s));
  const promise = (start) => new Promise((resolve, reject) => start(resolve, (m) => reject(new Error(m))));
  // Kept between launches (ModStorage), as Herdr keeps it.
  const storage = (() => { try { return JSON.parse(H.storageLoad()) ?? {}; } catch { return {}; } })();
  const persist = () => H.storageSave(JSON.stringify(storage));
  globalThis.localStorage = { getItem: (k) => storage[k] ?? null, setItem: (k, v) => { storage[k] = String(v); persist(); }, removeItem: (k) => { delete storage[k]; persist(); }, clear: () => { for (const k in storage) delete storage[k]; persist(); } };
  const herdr = {
    spaces: () => parse(H.data("spaces")), agents: () => parse(H.data("agents")), panes: () => parse(H.data("panes")),
    terminals: () => parse(H.data("terminals")), focused: () => parse(H.data("focused")), layout: () => parse(H.data("layout")),
    theme: () => parse(H.data("theme")), settings: () => parse(H.data("settings")), machines: () => [], layouts: () => [],
    keys: () => ({}), commands: () => [], window: () => ({ visible: true, focused: true, buttons: false }), placement: () => null,
    updates: () => ({}), telemetry: () => ({}),
    props: () => parse(H.data("props")) ?? {}, checking: () => false,
    shared: (k) => parse(H.shared(String(k))), setShared: (k, v) => H.setShared(String(k), JSON.stringify(v ?? null)),
    run: (name, args) => H.run(String(name), JSON.stringify(args ?? {})),
    notify: (n) => H.log("notify: " + JSON.stringify(n)),
    exec: (cmd, args, opts) => promise((ok, fail) => opts?.on ? fail("herdr-mac runs programs on this computer only") :
      H.exec(String(cmd), JSON.stringify(args ?? []), opts?.cwd ?? null, opts?.timeout ?? 30000, (r) => ok(JSON.parse(r)), fail)),
    hc: (args) => promise((ok, fail) => H.exec("hc", JSON.stringify(args ?? []), null, 30000, (r) => ok(JSON.parse(r)), fail)),
    readTextFile: (path, opts) => promise((ok, fail) => opts?.on ? fail("herdr-mac reads files on this computer only") : H.readTextFile(String(path), ok, fail)),
    writeTextFile: (path, text) => promise((ok, fail) => H.writeTextFile(String(path), String(text), ok, fail)),
    watchFolder: (dir) => { let id = null; const p = promise((ok, fail) => { id = H.watch(String(dir), (paths) => ok(JSON.parse(paths)), fail); }); p.cancel = () => H.unwatch(id); return p; },
    knownAgents: () => Promise.resolve([]), pickFolder: () => Promise.resolve(null), pickFiles: () => Promise.resolve(null),
    home: () => H.home(), appHome: () => H.appHome(),
    openOverlay: (o) => { H.log("openOverlay is not supported in herdr-mac yet: " + JSON.stringify(o?.mod ?? o)); return null; },
    closeOverlay: () => {}, nextCommand: () => new Promise(() => {}), setAgentOrder: () => {}, playSound: () => {},
    setWindowTitle: () => {}, setBadge: () => {}, presentUpdateNotes: () => {},
  };
  const builtins = { "gpui-kit": kit, "gpui-base": base, herdr };
  const cache = {};
  function load(path) {
    if (cache[path]) return cache[path];
    const exports = {};
    cache[path] = exports;
    const fn = (0, eval)(H.moduleSource(path));
    fn(exports, (spec) => builtins[spec] ?? load(H.resolve(path, spec)));
    return exports;
  }
})();
"""#
}
