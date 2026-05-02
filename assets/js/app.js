// Muse LiveView client — requires esbuild bundling to resolve phoenix deps.
// Full asset bundling remains a later step; this file is esbuild source only.
//
// When bundled, the output should replace the placeholder below and
// the <script> tag in HomeLive should point to the bundled output.

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// ─── DraggableWindow hook ──────────────────────────────────────────
//
// Makes a `.managed-window` element draggable by its `.window-title-bar`.
// Uses pointer events so it works on touch and mouse.  Persists position
// to localStorage keyed by the element's `id`.

const DraggableWindow = {
  mounted() {
    const el = this.el;
    const handle = el.querySelector(".window-title-bar");
    if (!handle) return;

    // Restore saved position
    const saved = localStorage.getItem("muse-win-" + el.id);
    if (saved) {
      try {
        const pos = JSON.parse(saved);
        el.style.left = pos.left;
        el.style.top = pos.top;
      } catch (_) { /* ignore */ }
    }

    let dragging = false;
    let offsetX = 0;
    let offsetY = 0;

    handle.addEventListener("pointerdown", (e) => {
      // Don't start drag from buttons or inputs inside the title bar
      if (e.target.closest("button, input, select, textarea")) return;
      dragging = true;
      const rect = el.getBoundingClientRect();
      offsetX = e.clientX - rect.left;
      offsetY = e.clientY - rect.top;
      handle.setPointerCapture(e.pointerId);
      e.preventDefault();
    });

    handle.addEventListener("pointermove", (e) => {
      if (!dragging) return;
      const newLeft = Math.max(0, e.clientX - offsetX);
      const newTop = Math.max(0, e.clientY - offsetY);
      el.style.left = newLeft + "px";
      el.style.top = newTop + "px";
      el.style.right = "auto";
    });

    handle.addEventListener("pointerup", (e) => {
      if (!dragging) return;
      dragging = false;
      // Persist position
      try {
        localStorage.setItem("muse-win-" + el.id, JSON.stringify({
          left: el.style.left,
          top: el.style.top
        }));
      } catch (_) { /* ignore */ }
    });
  }
};

// ─── Hooks & LiveSocket ───────────────────────────────────────────

let Hooks = {DraggableWindow};

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {hooks: Hooks, params: {_csrf_token: csrfToken}})
liveSocket.connect()
