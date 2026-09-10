// JS glue for the wasm backend (ADR-013, spec/adr/002 — the browser
// drives the loop via requestAnimationFrame, calling into aster_frame()
// directly; this file owns no frame logic of its own).
//
// Implements the "aster" import namespace src/backends/wasm/backend.zig
// and src/host/fs_wasm.zig declare as `extern "aster" fn ...`, plus the
// canvas/keyboard/mouse wiring a real page needs. Loaded as a plain
// <script> (no bundler, no build step beyond `zig build` itself —
// CONTRIBUTING.md's "zig build is the interface").
//
// tools/wasm-conformance.js requires this same file and runs the host
// contract against `hostImports` below with a Map instead of
// localStorage, so what the suite certifies is the code the browser
// actually runs — not a second implementation of the same eleven imports
// that has to be kept in step by hand (B25, B28).

(function (root, factory) {
  "use strict";
  const api = factory();
  // Two callers, no bundler: a browser <script> (docs/demo/index.html)
  // and `require` from Node (tools/wasm-conformance.js).
  if (typeof module === "object" && module.exports) module.exports = api;
  else {
    root.Aster = api.Aster;
    root.attachAsterInput = api.attachInput;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  // ---- bytes in, bytes out ----------------------------------------------
  //
  // host.read/host.write carry Lua strings, which are byte strings, not
  // text — spec/host-contract.md §3.8. Decoding them as UTF-8 would turn
  // every byte a `wm.lua` happens to contain that isn't valid UTF-8 into
  // U+FFFD and change the file's length, so each byte becomes one code
  // unit 0-255 instead and survives localStorage's UTF-16 round trip
  // unchanged (B28).

  function bytesToStore(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length; i += 4096) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, i + 4096));
    }
    return out;
  }
  function bytesFromStore(str) {
    const bytes = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) bytes[i] = str.charCodeAt(i) & 0xff;
    return bytes;
  }

  // ---- the filesystem fs_wasm.zig's two-phase protocol talks to ---------
  //
  // A `store` is the small interface hostImports needs: get/set/remove one
  // path, and list the paths under a directory. localStorage backs it in
  // the browser (below); the conformance runner passes a Map-backed one.

  const STORAGE_PREFIX = "aster:fs:";

  // Every path is one localStorage entry, prefixed so aster's own keys
  // don't collide with anything else on the page's origin.
  function localStorageStore() {
    // localStorage itself has no mtime concept, so one is tracked here,
    // in memory, keyed by path. Only set()/remove() advance it — a path
    // read but never written this session gets a stable (not wall-clock)
    // mtime the first time it's asked for, since loop.lua's external-edit
    // watch (spec/architecture.md "Reload preserves state") compares this
    // value across ticks for *equality*, not absolute time: returning
    // Date.now() here instead made every list() call report a "changed"
    // file, forcing a reload on essentially every animation frame (B38).
    const mtimes = new Map();
    function touch(path) {
      mtimes.set(path, Math.floor(Date.now() / 1000));
    }
    function mtimeOf(path) {
      if (!mtimes.has(path)) mtimes.set(path, 0);
      return mtimes.get(path);
    }
    return {
      get(path) {
        const v = localStorage.getItem(STORAGE_PREFIX + path);
        return v === null ? null : bytesFromStore(v);
      },
      set(path, bytes) {
        localStorage.setItem(STORAGE_PREFIX + path, bytesToStore(bytes));
        touch(path);
      },
      remove(path) {
        const had = localStorage.getItem(STORAGE_PREFIX + path) !== null;
        localStorage.removeItem(STORAGE_PREFIX + path);
        mtimes.delete(path);
        return had;
      },
      // `dir` has no trailing slash (host.list's contract); entries come
      // back bare, matching fs_native.zig's real directory iteration.
      keysUnder(dir) {
        const dirPrefix = STORAGE_PREFIX + dir + "/";
        const out = [];
        for (let i = 0; i < localStorage.length; i++) {
          const k = localStorage.key(i);
          if (k.startsWith(dirPrefix)) out.push(k.slice(dirPrefix.length));
        }
        return out;
      },
      mtime(path) {
        return mtimeOf(path);
      },
    };
  }

  // ---- physical-key vocabulary (spec/keys.md) — KeyboardEvent.code is
  // layout-independent, matching the contract's "key_down carries the
  // physical key" rule exactly; KeyboardEvent.key is used only for the
  // `text` event (post-layout, see below).

  const CODE_TO_KEY = {
    KeyA: "a", KeyB: "b", KeyC: "c", KeyD: "d", KeyE: "e", KeyF: "f", KeyG: "g",
    KeyH: "h", KeyI: "i", KeyJ: "j", KeyK: "k", KeyL: "l", KeyM: "m", KeyN: "n",
    KeyO: "o", KeyP: "p", KeyQ: "q", KeyR: "r", KeyS: "s", KeyT: "t", KeyU: "u",
    KeyV: "v", KeyW: "w", KeyX: "x", KeyY: "y", KeyZ: "z",
    Digit0: "0", Digit1: "1", Digit2: "2", Digit3: "3", Digit4: "4",
    Digit5: "5", Digit6: "6", Digit7: "7", Digit8: "8", Digit9: "9",
    Space: "space", Enter: "enter", Escape: "escape", Tab: "tab",
    Backspace: "backspace", Delete: "delete", Insert: "insert",
    ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right",
    Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown",
    F1: "f1", F2: "f2", F3: "f3", F4: "f4", F5: "f5", F6: "f6",
    F7: "f7", F8: "f8", F9: "f9", F10: "f10", F11: "f11", F12: "f12",
    Minus: "minus", Equal: "equals", BracketLeft: "bracketleft",
    BracketRight: "bracketright", Semicolon: "semicolon", Quote: "apostrophe",
    Backquote: "grave", Backslash: "backslash", Comma: "comma",
    Period: "period", Slash: "slash",
  };

  // ---- the eleven "aster" imports the wasm module declares -------------
  //
  // Everything that differs between a browser tab and the conformance
  // runner arrives in `env`: where linear memory is, where files live,
  // what present and log do. Nothing below knows which one it is talking
  // to, which is the point — tools/wasm-conformance.js certifies this
  // exact code.

  function hostImports(env) {
    const mem = () => env.memory();
    // Paths cross the boundary as bytes and are used as store keys, so
    // they get the same byte-exact treatment file contents do.
    const readPath = (ptr, len) => bytesToStore(new Uint8Array(mem(), ptr, len));

    return {
      js_log: (ptr, len) => {
        env.log(new TextDecoder().decode(new Uint8Array(mem(), ptr, len)));
      },
      js_wall_clock_ms: () => Date.now(),
      js_utc_offset_min: () => -new Date().getTimezoneOffset(),
      js_now_ms: () => performance.now(),
      js_present: (ptr, len, w, h) => env.present(ptr, len, w, h),

      js_fs_read: (pathPtr, pathLen, outPtr, outCap) => {
        const bytes = env.store.get(readPath(pathPtr, pathLen));
        if (bytes === null) return -1;
        if (bytes.length > outCap) return -2;
        new Uint8Array(mem(), outPtr, bytes.length).set(bytes);
        return bytes.length;
      },
      js_fs_write: (pathPtr, pathLen, dataPtr, dataLen) => {
        const path = readPath(pathPtr, pathLen);
        // Copied, not a view: the store outlives this call, and linear
        // memory moves under it the moment wasm grows the heap.
        const data = new Uint8Array(mem(), dataPtr, dataLen).slice();
        try {
          env.store.set(path, data);
          return 0;
        } catch (e) {
          return -2; // localStorage quota exceeded -> no_space
        }
      },
      js_fs_list_count: (pathPtr, pathLen) => {
        return env.store.keysUnder(readPath(pathPtr, pathLen)).length;
      },
      js_fs_list_entry: (pathPtr, pathLen, index, nameOutPtr, nameCap, isDirOutPtr, sizeOutPtr, mtimeOutPtr) => {
        const dir = readPath(pathPtr, pathLen);
        const name = env.store.keysUnder(dir)[index];
        if (name === undefined) return -1;
        const bytes = bytesFromStore(name);
        if (bytes.length > nameCap) return -1;
        new Uint8Array(mem(), nameOutPtr, bytes.length).set(bytes);
        const view = new DataView(mem());
        view.setInt32(isDirOutPtr, 0, true);
        const entryPath = dir + "/" + name;
        const value = env.store.get(entryPath);
        view.setBigInt64(sizeOutPtr, BigInt(value === null ? 0 : value.length), true);
        view.setBigInt64(mtimeOutPtr, BigInt(env.store.mtime(entryPath)), true);
        return bytes.length;
      },
      js_fs_remove: (pathPtr, pathLen) => {
        // Recursive, per spec/host-contract.md: the exact path and
        // everything nested under it (B25).
        const path = readPath(pathPtr, pathLen);
        let found = env.store.remove(path);
        for (const name of env.store.keysUnder(path)) {
          if (env.store.remove(path + "/" + name)) found = true;
        }
        return found ? 0 : -1;
      },
      js_fs_rename: (fromPtr, fromLen, toPtr, toLen) => {
        const from = readPath(fromPtr, fromLen);
        const to = readPath(toPtr, toLen);
        const value = env.store.get(from);
        if (value === null) return -1;
        if (env.store.get(to) !== null) return -2;
        env.store.set(to, value);
        env.store.remove(from);
        return 0;
      },
    };
  }

  class Aster {
    constructor(canvas) {
      this.canvas = canvas;
      this.ctx = canvas.getContext("2d");
      this.instance = null;
    }

    async load(wasmUrl) {
      const bytes = await (await fetch(wasmUrl)).arrayBuffer();
      const imports = { aster: this._imports() };
      const { instance } = await WebAssembly.instantiate(bytes, imports);
      this.instance = instance;
      return this;
    }

    _mem() {
      return this.instance.exports.memory.buffer;
    }

    // Writes a JS string into wasm memory via its own malloc, returning
    // [ptr, len] — the pattern every event push below uses to hand a
    // string across the wasm boundary (a wasm import can only pass
    // numbers, see backend.zig's header comment). Key names and typed
    // text are text, so UTF-8 is right here; file contents are not, which
    // is what hostImports handles byte-exactly instead.
    _writeString(str) {
      const bytes = new TextEncoder().encode(str);
      const ptr = this.instance.exports.malloc(bytes.length || 1);
      new Uint8Array(this._mem(), ptr, bytes.length).set(bytes);
      return [ptr, bytes.length];
    }
    _freeString(ptr) {
      this.instance.exports.free(ptr);
    }

    _imports() {
      return hostImports({
        memory: () => this._mem(),
        store: localStorageStore(),
        present: (ptr, len, w, h) => this._present(ptr, len, w, h),
        log: (line) => console.log(line),
      });
    }

    // xrgb8888 (little-endian, per spec/host-contract.md §3.4) -> canvas
    // RGBA: in memory each pixel's bytes are [B, G, R, pad]; ImageData
    // wants [R, G, B, A]. Re-sized on every resize (see resize() below),
    // so this can just recreate the ImageData each present() call.
    _present(ptr, len, w, h) {
      if (this.canvas.width !== w || this.canvas.height !== h) {
        this.canvas.width = w;
        this.canvas.height = h;
      }
      const src = new Uint8Array(this._mem(), ptr, len * 4);
      const img = this.ctx.createImageData(w, h);
      const dst = img.data;
      for (let i = 0; i < len; i++) {
        dst[i * 4 + 0] = src[i * 4 + 2]; // R
        dst[i * 4 + 1] = src[i * 4 + 1]; // G
        dst[i * 4 + 2] = src[i * 4 + 0]; // B
        dst[i * 4 + 3] = 255; // A
      }
      this.ctx.putImageData(img, 0, 0);
    }

    init(w, h) {
      this.canvas.width = w;
      this.canvas.height = h;
      this.instance.exports.aster_init(w, h);
    }
    boot() {
      this.instance.exports.aster_boot();
    }
    shutdown() {
      this.instance.exports.aster_shutdown();
    }

    // Returns "running" | "idle" | "quit" (aster_frame()'s 0/1/2, per
    // ADR-002's own JS example).
    frame() {
      const status = this.instance.exports.aster_frame();
      return ["running", "idle", "quit"][status] ?? "quit";
    }

    // requestAnimationFrame drives the loop directly — ADR-002's whole
    // point is that this needs no asyncify and no special-casing.
    run() {
      const tick = () => {
        if (this.frame() === "quit") {
          this.shutdown(); // contract: "quit" means stop calling frame *and* call shutdown
          return;
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }

    pushKeyDown(code, mods) {
      const key = CODE_TO_KEY[code];
      if (!key) return;
      const [ptr, len] = this._writeString(key);
      this.instance.exports.aster_push_key_down(ptr, len, mods.ctrl | 0, mods.alt | 0, mods.shift | 0, mods.super | 0);
      this._freeString(ptr);
    }
    pushKeyUp(code, mods) {
      const key = CODE_TO_KEY[code];
      if (!key) return;
      const [ptr, len] = this._writeString(key);
      this.instance.exports.aster_push_key_up(ptr, len, mods.ctrl | 0, mods.alt | 0, mods.shift | 0, mods.super | 0);
      this._freeString(ptr);
    }
    pushText(str) {
      const [ptr, len] = this._writeString(str);
      this.instance.exports.aster_push_text(ptr, len);
      this._freeString(ptr);
    }
    pushMouseMove(x, y, dx, dy) {
      this.instance.exports.aster_push_mouse_move(x | 0, y | 0, dx | 0, dy | 0);
    }
    pushMouseDown(x, y, button) {
      this.instance.exports.aster_push_mouse_down(x | 0, y | 0, button | 0);
    }
    pushMouseUp(x, y, button) {
      this.instance.exports.aster_push_mouse_up(x | 0, y | 0, button | 0);
    }
    pushScroll(x, y, dx, dy) {
      this.instance.exports.aster_push_scroll(x | 0, y | 0, dx | 0, dy | 0);
    }
    pushResize(w, h) {
      this.instance.exports.aster_push_resize(w >>> 0, h >>> 0);
    }
    pushFocus(focused) {
      this.instance.exports.aster_push_focus(focused ? 1 : 0);
    }
    pushQuit() {
      this.instance.exports.aster_push_quit();
    }
  }

  // Wires standard DOM listeners on `canvas` to the push* calls above —
  // split out from Aster itself so a caller with an unusual input setup
  // (the conformance runner, say) can skip it and drive events directly.
  function attachInput(aster, canvas) {
    // A <canvas> can never receive `beforeinput` — that event is part of
    // the InputEvent spec's editing-host contract (a real <input>/
    // <textarea>/contenteditable element), not something a focusable-but-
    // otherwise-plain element gets no matter how the keypress arrives,
    // real hardware or synthetic. Confirmed empirically: canvas.tabIndex=0
    // plus a focused canvas still fires zero beforeinput events. See B37
    // in spec/troubleshooting.md. Keyboard focus (and so keydown/keyup/
    // beforeinput/focus/blur) therefore lives on this invisible <input>
    // instead — the canvas keeps only the mouse listeners and its own
    // pixels; nothing about what the page LOOKS like changes.
    const keyboardProxy = document.createElement("input");
    keyboardProxy.type = "text";
    keyboardProxy.autocomplete = "off";
    keyboardProxy.spellcheck = false;
    keyboardProxy.setAttribute("aria-hidden", "true");
    Object.assign(keyboardProxy.style, {
      position: "fixed", left: "0", top: "0", width: "1px", height: "1px",
      opacity: "0", border: "0", padding: "0", pointerEvents: "none",
    });
    (canvas.parentNode || document.body).insertBefore(keyboardProxy, canvas.nextSibling);
    canvas.tabIndex = 0; // canvas.focus() (index.html) still works — it just redirects, below
    let lastX = 0, lastY = 0;

    function modsOf(e) {
      return { ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, super: e.metaKey };
    }

    // No unconditional e.preventDefault() here (unlike the old canvas
    // listener this replaced): on a real <input>, preventing keydown's
    // default action also suppresses the browser's own character-
    // insertion step for that keystroke — which is exactly the step
    // `beforeinput` below depends on. Only suppressed for a
    // modifier-decorated keystroke (Ctrl+S, Super+Z, a global
    // keybinding's own combo): those aren't meant to type a character at
    // all, and on at least one tested environment a held Super (mapped
    // from OS "Meta") didn't fully suppress the browser's own text
    // composition, leaking the plain letter into the buffer alongside the
    // keybinding firing.
    keyboardProxy.addEventListener("keydown", (e) => {
      if (e.repeat) return;
      aster.pushKeyDown(e.code, modsOf(e));
      if (e.ctrlKey || e.altKey || e.metaKey) e.preventDefault();
    });
    keyboardProxy.addEventListener("keyup", (e) => {
      aster.pushKeyUp(e.code, modsOf(e));
    });
    // `text`, not `key_down`, carries typed characters (spec/keys.md:
    // "keys are not text") — beforeinput's `.data` is already
    // post-layout/IME, exactly what the contract wants.
    keyboardProxy.addEventListener("beforeinput", (e) => {
      if (e.data) aster.pushText(e.data);
    });
    // The proxy's own value is never meant to hold anything — clear it
    // after every edit (a typed char, an IME commit, ...) so it can't
    // grow without bound or get out of sync with anything.
    keyboardProxy.addEventListener("input", () => { keyboardProxy.value = ""; });
    keyboardProxy.addEventListener("focus", () => aster.pushFocus(true));
    keyboardProxy.addEventListener("blur", () => aster.pushFocus(false));
    canvas.addEventListener("focus", () => keyboardProxy.focus());

    canvas.addEventListener("mousemove", (e) => {
      const r = canvas.getBoundingClientRect();
      const x = Math.round(e.clientX - r.left);
      const y = Math.round(e.clientY - r.top);
      aster.pushMouseMove(x, y, x - lastX, y - lastY);
      lastX = x;
      lastY = y;
    });
    canvas.addEventListener("mousedown", (e) => {
      keyboardProxy.focus();
      const r = canvas.getBoundingClientRect();
      aster.pushMouseDown(Math.round(e.clientX - r.left), Math.round(e.clientY - r.top), e.button);
    });
    canvas.addEventListener("mouseup", (e) => {
      const r = canvas.getBoundingClientRect();
      aster.pushMouseUp(Math.round(e.clientX - r.left), Math.round(e.clientY - r.top), e.button);
    });
    canvas.addEventListener("wheel", (e) => {
      const r = canvas.getBoundingClientRect();
      aster.pushScroll(
        e.clientX - r.left, e.clientY - r.top,
        Math.sign(e.deltaX), -Math.sign(e.deltaY)
      );
      e.preventDefault();
    }, { passive: false });
    canvas.addEventListener("contextmenu", (e) => e.preventDefault());

    // The browser's analog of SDL_EVENT_QUIT (the window's close button):
    // the tab is going away, with no guarantee run()'s next
    // requestAnimationFrame ever fires, so push the event and drain it
    // synchronously instead of waiting for the loop to notice (see B29
    // in spec/troubleshooting.md).
    window.addEventListener("beforeunload", () => {
      aster.pushQuit();
      if (aster.frame() === "quit") aster.shutdown();
    });
  }

  return { Aster, attachInput, hostImports, localStorageStore, bytesToStore, bytesFromStore };
});
