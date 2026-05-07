// Muse LiveView client — requires esbuild bundling to resolve phoenix deps.
// Full asset bundling remains a later step; this file is esbuild source only.

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// ─── DraggableWindow hook ──────────────────────────────────────────
//
// Makes a `.managed-window` element draggable by its `.window-title-bar`.
// Uses pointer events so it works on touch and mouse.  Persists position
// to localStorage keyed by the element's id.

const DraggableWindow = {
  mounted() {
    const el = this.el;
    const handle = el.querySelector(".window-title-bar");
    if (!handle) return;

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

    const onPointerMove = (e) => {
      if (!dragging) return;
      const newLeft = Math.max(0, e.clientX - offsetX);
      const newTop = Math.max(0, e.clientY - offsetY);
      el.style.left = newLeft + "px";
      el.style.top = newTop + "px";
      el.style.right = "auto";
    };

    const onPointerUp = () => {
      if (!dragging) return;
      dragging = false;
      document.removeEventListener("pointermove", onPointerMove);
      document.removeEventListener("pointerup", onPointerUp);
      try {
        localStorage.setItem("muse-win-" + el.id, JSON.stringify({
          left: el.style.left,
          top: el.style.top
        }));
      } catch (_) { /* ignore */ }
    };

    handle.addEventListener("pointerdown", (e) => {
      if (e.target.closest("button, input, select, textarea")) return;
      dragging = true;
      const rect = el.getBoundingClientRect();
      offsetX = e.clientX - rect.left;
      offsetY = e.clientY - rect.top;
      document.addEventListener("pointermove", onPointerMove);
      document.addEventListener("pointerup", onPointerUp);
      e.preventDefault();
    });
  }
};

// ─── Clipboard helper ────────────────────────────────────────────
//
// Tries navigator.clipboard.writeText; falls back to hidden textarea trick.

function copyToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
  }
  return Promise.resolve(fallbackCopy(text));
}

function fallbackCopy(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  ta.style.top = "-9999px";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); } catch (_) { /* ignore */ }
  document.body.removeChild(ta);
}

// ─── CommandConsole hook ────────────────────────────────────────────
//
// Auto-scrolls the command history and supports Enter/Shift+Enter
// for the textarea. Enter submits, Shift+Enter adds a newline.
// Also provides slash command autocomplete and command history navigation.

const CommandConsole = {
  mounted() {
    const history = this.el.querySelector("#command-history");
    if (history) {
      const observer = new MutationObserver(() => {
        history.scrollTop = history.scrollHeight;
      });
      observer.observe(history, { childList: true, subtree: true });
      this._historyObserver = observer;
    }

    // Parse slash commands from data attribute
    this._slashCommands = [];
    try {
      const raw = this.el.dataset.slashCommands;
      if (raw) this._slashCommands = JSON.parse(raw);
    } catch (_) { /* ignore */ }

    const textarea = this.el.querySelector("textarea[name='text']");
    if (textarea) {
      this._textarea = textarea;
      this._suggestionsActive = false;
      this._selectedSuggestion = -1;
      this._historyIndex = -1;

      // Create autocomplete dropdown
      const suggestionBoxId = (textarea.id || "chat-input-textarea") + "-command-suggestions";
      this._suggestionBoxId = suggestionBoxId;
      this._suggestionBox = document.createElement("div");
      this._suggestionBox.className = "command-suggestions";
      this._suggestionBox.id = suggestionBoxId;
      this._suggestionBox.setAttribute("role", "listbox");
      this._suggestionBox.setAttribute("aria-label", "Command suggestions");
      this._suggestionBox.style.display = "none";
      textarea.parentNode.insertBefore(this._suggestionBox, textarea.nextSibling);

      // ARIA combobox relationships on the textarea
      textarea.setAttribute("aria-autocomplete", "list");
      textarea.setAttribute("aria-controls", suggestionBoxId);
      textarea.setAttribute("aria-expanded", "false");
      textarea.removeAttribute("aria-activedescendant");

      textarea.addEventListener("keydown", (e) => {
        if (this._suggestionsActive) {
          if (e.key === "ArrowDown") {
            e.preventDefault();
            this._selectedSuggestion = Math.min(
              this._selectedSuggestion + 1,
              this._suggestionBox.children.length - 1
            );
            this._highlightSuggestion();
            return;
          }
          if (e.key === "ArrowUp") {
            e.preventDefault();
            this._selectedSuggestion = Math.max(this._selectedSuggestion - 1, 0);
            this._highlightSuggestion();
            return;
          }
          if (e.key === "Enter" || e.key === "Tab") {
            e.preventDefault();
            this._acceptSuggestion();
            return;
          }
          if (e.key === "Escape") {
            e.preventDefault();
            this._closeSuggestions();
            return;
          }
        } else {
          // History navigation when suggestions not active
          if (e.key === "ArrowUp" && textarea.selectionStart === 0) {
            e.preventDefault();
            this._navigateHistory(-1);
            return;
          }
          if (e.key === "ArrowDown" && textarea.selectionStart >= textarea.value.length) {
            e.preventDefault();
            this._navigateHistory(1);
            return;
          }
        }

        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault();
          // Save to history before submit
          const val = textarea.value.trim();
          if (val) this._pushHistory(val);
          const form = textarea.closest("form");
          if (form) {
            if (typeof form.requestSubmit === "function") {
              form.requestSubmit();
            } else {
              form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
            }
          }
        }
      });

      textarea.addEventListener("input", () => {
        textarea.style.height = "auto";
        textarea.style.height = Math.min(textarea.scrollHeight, 120) + "px";
        this._updateSuggestions();
      });

      // Close suggestions on blur (with small delay for click handling)
      textarea.addEventListener("blur", () => {
        setTimeout(() => this._closeSuggestions(), 150);
      });

      textarea.addEventListener("focus", () => {
        this._updateSuggestions();
      });
    }

    this.handleEvent("clear_command_input", () => {
      this._clearTextarea();
    });
  },

  destroyed() {
    if (this._historyObserver) {
      this._historyObserver.disconnect();
    }
    if (this._suggestionBox && this._suggestionBox.parentNode) {
      this._suggestionBox.parentNode.removeChild(this._suggestionBox);
    }
  },

  _updateSuggestions() {
    const textarea = this._textarea;
    if (!textarea) return;
    const val = textarea.value;

    if (!val.startsWith("/")) {
      this._closeSuggestions();
      return;
    }

    const query = val.toLowerCase();
    const matches = this._slashCommands.filter(c =>
      c.command.toLowerCase().startsWith(query) ||
      c.command.toLowerCase().includes(query)
    );

    if (matches.length === 0 || (matches.length === 1 && matches[0].command.toLowerCase() === query)) {
      this._closeSuggestions();
      return;
    }

    this._suggestionBox.innerHTML = "";
    matches.forEach((cmd, i) => {
      const item = document.createElement("div");
      item.className = "command-suggestion-item";
      item.id = this._suggestionBoxId + "-option-" + i;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      item.innerHTML = `<span class="suggestion-cmd">${this._escapeHtml(cmd.command)}</span><span class="suggestion-desc">${this._escapeHtml(cmd.description)}</span>`;
      item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this._textarea.value = cmd.command + " ";
        this._textarea.focus();
        this._closeSuggestions();
      });
      this._suggestionBox.appendChild(item);
    });

    this._suggestionBox.style.display = "block";
    this._suggestionsActive = true;
    this._selectedSuggestion = -1;
    this._textarea.setAttribute("aria-expanded", "true");
    this._textarea.removeAttribute("aria-activedescendant");
  },

  _highlightSuggestion() {
    const items = this._suggestionBox.children;
    for (let i = 0; i < items.length; i++) {
      items[i].classList.toggle("suggestion-selected", i === this._selectedSuggestion);
      items[i].setAttribute("aria-selected", i === this._selectedSuggestion ? "true" : "false");
    }
    if (this._selectedSuggestion >= 0 && items[this._selectedSuggestion]) {
      items[this._selectedSuggestion].scrollIntoView({ block: "nearest" });
      this._textarea.setAttribute("aria-activedescendant", items[this._selectedSuggestion].id);
    } else {
      this._textarea.removeAttribute("aria-activedescendant");
    }
  },

  _acceptSuggestion() {
    const items = this._suggestionBox.children;
    // If nothing is selected but suggestions are visible, accept the first one
    const idx = this._selectedSuggestion >= 0 ? this._selectedSuggestion : 0;
    if (idx >= 0 && items[idx]) {
      const matches = this._slashCommands.filter(c => {
        const q = this._textarea.value.toLowerCase();
        return c.command.toLowerCase().startsWith(q) || c.command.toLowerCase().includes(q);
      });
      const cmd = matches[idx];
      if (cmd) {
        this._textarea.value = cmd.command + " ";
      }
    }
    this._closeSuggestions();
    this._textarea.focus();
  },

  _closeSuggestions() {
    this._suggestionBox.style.display = "none";
    this._suggestionsActive = false;
    this._selectedSuggestion = -1;
    if (this._textarea) {
      this._textarea.setAttribute("aria-expanded", "false");
      this._textarea.removeAttribute("aria-activedescendant");
    }
  },

  _escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  },

  _clearTextarea() {
    if (!this._textarea) return;
    this._textarea.value = "";
    this._textarea.style.height = "auto";
    this._closeSuggestions();
    this._historyIndex = -1;
  },

  _navigateHistory(direction) {
    const history = this._loadHistory();
    if (history.length === 0) return;

    if (direction === -1) {
      // Up: go back in time
      if (this._historyIndex < history.length - 1) {
        this._historyIndex++;
      }
    } else {
      // Down: go forward in time
      if (this._historyIndex > 0) {
        this._historyIndex--;
      } else {
        this._historyIndex = -1;
        this._textarea.value = "";
        return;
      }
    }

    this._textarea.value = history[history.length - 1 - this._historyIndex] || "";
  },

  _loadHistory() {
    try {
      return JSON.parse(localStorage.getItem("muse-cmd-history") || "[]");
    } catch (_) { return []; }
  },

  _pushHistory(cmd) {
    const history = this._loadHistory();
    // Don't duplicate the most recent entry
    if (history[history.length - 1] === cmd) return;
    history.push(cmd);
    // Cap at 100 entries
    while (history.length > 100) history.shift();
    try {
      localStorage.setItem("muse-cmd-history", JSON.stringify(history));
    } catch (_) { /* ignore */ }
    this._historyIndex = -1;
  }
};

// ─── ToastAutoDismiss hook ──────────────────────────────────────────
//
// Adds a progress-bar animation to toasts. Actual dismiss is handled
// server-side via Process.send_after.

const ToastAutoDismiss = {
  mounted() {
    // Fallback: if server dismiss doesn't arrive, remove after 6s
    this._timer = setTimeout(() => {
      this.el.style.opacity = "0";
      this.el.style.transform = "translateY(8px)";
      this.el.style.transition = "opacity 0.3s, transform 0.3s";
      setTimeout(() => { this.el.remove(); }, 300);
    }, 6000);
  },
  destroyed() {
    if (this._timer) clearTimeout(this._timer);
  }
};

// ─── Keyboard shortcuts hook ────────────────────────────────────────
//
// Global keyboard shortcuts shell.
// Esc closes diagnostics drawer. Ctrl+/ focuses command input.
// Ctrl/Cmd+K opens command palette.

const KeyboardShortcuts = {
  mounted() {
    this._handler = (e) => {
      // Esc: close diagnostics drawer if open (and close command palette)
      if (e.key === "Escape") {
        const drawer = document.getElementById("diagnostics-drawer");
        if (drawer) {
          const btn = drawer.querySelector(".diagnostics-collapse-btn");
          if (btn) btn.click();
        }
        // Close command palette
        const palette = document.getElementById("command-palette");
        if (palette && palette.style.display !== "none") {
          palette.style.display = "none";
        }
      }
      // Ctrl+/ or Cmd+/: focus command input
      if ((e.ctrlKey || e.metaKey) && e.key === "/") {
        e.preventDefault();
        const input = document.querySelector(".command-input");
        if (input) input.focus();
      }
      // Ctrl/Cmd+K: open command palette
      if ((e.ctrlKey || e.metaKey) && e.key === "k") {
        e.preventDefault();
        const palette = document.getElementById("command-palette");
        if (palette) {
          const hook = palette.__liveViewHook;
          if (hook && hook.open) {
            hook.open();
          } else {
            // Direct DOM fallback
            palette.style.display = "flex";
            const input = palette.querySelector(".command-palette-input");
            if (input) input.focus();
          }
        }
      }

    };
    document.addEventListener("keydown", this._handler);
  },
  destroyed() {
    if (this._handler) {
      document.removeEventListener("keydown", this._handler);
    }
  }
};

// ─── CommandPalette hook ──────────────────────────────────────────
//
// Command palette opened by Ctrl/Cmd+K. Provides quick actions
// and slash commands with keyboard navigation.

const CommandPalette = {
  mounted() {
    this.el.__liveViewHook = this;
    this._actions = [];
    try {
      const raw = this.el.dataset.paletteActions;
      if (raw) this._actions = JSON.parse(raw);
    } catch (_) { /* ignore */ }

    // Add slash commands to the actions list
    const consoleEl = document.getElementById("input-form");
    if (consoleEl) {
      try {
        const raw = consoleEl.dataset.slashCommands;
        if (raw) {
          const cmds = JSON.parse(raw);
          cmds.forEach(c => {
            this._actions.push({
              id: "slash:" + c.command,
              label: c.command,
              icon: "⌨️",
              description: c.description
            });
          });
        }
      } catch (_) { /* ignore */ }
    }

    this._input = this.el.querySelector(".command-palette-input");
    this._list = this.el.querySelector("#command-palette-list");
    this._backdrop = this.el.querySelector(".command-palette-backdrop");
    this._selectedIndex = -1;
    this._filteredActions = this._actions;

    if (this._backdrop) {
      this._backdrop.addEventListener("click", () => this.close());
    }

    if (this._input) {
      this._input.addEventListener("input", () => this._filterActions());
      this._input.addEventListener("keydown", (e) => {
        if (e.key === "ArrowDown") {
          e.preventDefault();
          this._selectedIndex = Math.min(this._selectedIndex + 1, this._filteredActions.length - 1);
          this._highlightItem();
        } else if (e.key === "ArrowUp") {
          e.preventDefault();
          this._selectedIndex = Math.max(this._selectedIndex - 1, 0);
          this._highlightItem();
        } else if (e.key === "Enter") {
          e.preventDefault();
          this._selectCurrent();
        } else if (e.key === "Escape") {
          e.preventDefault();
          this.close();
        }
      });
    }
  },

  open() {
    this.el.style.display = "flex";
    if (this._input) {
      this._input.value = "";
      this._input.focus();
    }
    this._filterActions();
  },

  close() {
    this.el.style.display = "none";
    if (this._input) this._input.value = "";
    this._selectedIndex = -1;
  },

  _filterActions() {
    const query = (this._input ? this._input.value : "").toLowerCase();
    this._filteredActions = this._actions.filter(a =>
      a.label.toLowerCase().includes(query) ||
      (a.description && a.description.toLowerCase().includes(query)) ||
      (a.shortcut && a.shortcut.toLowerCase().includes(query))
    );
    this._selectedIndex = -1;
    this._renderList();
  },

  _renderList() {
    if (!this._list) return;
    this._list.innerHTML = "";
    this._filteredActions.forEach((action, i) => {
      const li = document.createElement("li");
      li.className = "palette-item";
      li.setAttribute("role", "option");
      li.setAttribute("aria-selected", "false");
      li.innerHTML = `<span class="palette-item-icon">${action.icon || ""}</span>` +
        `<span class="palette-item-label">${this._escapeHtml(action.label)}</span>` +
        (action.shortcut ? `<span class="palette-item-shortcut">${this._escapeHtml(action.shortcut)}</span>` : "");
      li.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this._executeAction(action);
      });
      this._list.appendChild(li);
    });
  },

  _highlightItem() {
    const items = this._list ? this._list.children : [];
    for (let i = 0; i < items.length; i++) {
      items[i].classList.toggle("palette-item-selected", i === this._selectedIndex);
      items[i].setAttribute("aria-selected", i === this._selectedIndex ? "true" : "false");
    }
    if (this._selectedIndex >= 0 && items[this._selectedIndex]) {
      items[this._selectedIndex].scrollIntoView({ block: "nearest" });
    }
  },

  _selectCurrent() {
    if (this._selectedIndex >= 0 && this._filteredActions[this._selectedIndex]) {
      this._executeAction(this._filteredActions[this._selectedIndex]);
    }
  },

  _executeAction(action) {
    const actionId = action.id;
    this.close();

    // Slash commands go through the console
    if (actionId.startsWith("slash:")) {
      const cmd = actionId.replace("slash:", "");
      const textarea = document.querySelector("textarea[name='text']");
      const form = textarea ? textarea.closest("form") : null;
      if (textarea && form) {
        textarea.value = cmd;
        if (typeof form.requestSubmit === "function") {
          form.requestSubmit();
        } else {
          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
        }
      }
      return;
    }

    // Push action to LiveView
    this.pushEvent("command_palette_action", { action: actionId });
  },

  _escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }
};

// ─── Handle LiveView push_event for clipboard ──────────────────────
//
// Listens for "copy_to_clipboard" events from the server and
// copies the text to the user's clipboard.

const ClipboardHandler = {
  mounted() {
    this.handleEvent("copy_to_clipboard", ({ text, label }) => {
      copyToClipboard(text).then(() => {
        // Show a brief toast-like notification
        showToastNotification(label ? `Copied: ${label}` : "Copied to clipboard");
      }).catch(() => {
        showToastNotification("Copy failed — use manual copy");
      });
    });

    this.handleEvent("jump_to_file", ({ file, line }) => {
      const msg = line ? `File: ${file}:${line}` : `File: ${file}`;
      showToastNotification(msg);
      window.dispatchEvent(new CustomEvent("muse:jump-to-file", { detail: { file, line } }));
    });
  }
};

function showToastNotification(message) {
  let container = document.getElementById("clipboard-toast-container");
  if (!container) {
    container = document.createElement("div");
    container.id = "clipboard-toast-container";
    container.style.cssText = "position:fixed;bottom:80px;right:24px;z-index:1200;display:flex;flex-direction:column;gap:8px;pointer-events:none;max-width:320px;";
    document.body.appendChild(container);
  }
  const toast = document.createElement("div");
  toast.style.cssText = "padding:8px 16px;background:rgba(15,17,23,0.95);border:1px solid rgba(139,92,246,0.32);border-radius:10px;color:#eef0f6;font-size:13px;font-family:Inter,sans-serif;pointer-events:auto;animation:toast-in 0.2s ease-out;";
  toast.textContent = message;
  container.appendChild(toast);
  setTimeout(() => {
    toast.style.opacity = "0";
    toast.style.transition = "opacity 0.3s";
    setTimeout(() => toast.remove(), 300);
  }, 2500);
}

// ─── MobileSidebar hook ─────────────────────────────────────────
//
// Implements WCAG modal overlay pattern for the mobile context sidebar.
// When the sidebar is expanded on a narrow viewport (≤960px):
//   - Moves focus into the sidebar (ideally the Hide button)
//   - Makes background elements inert / aria-hidden
//   - Traps Tab/Shift+Tab within sidebar controls
//   - Escape closes the sidebar and restores focus to the mobile toggle
//   - Backdrop click closes the sidebar (via Phoenix phx-click)
// On resize to desktop or sidebar collapse, reverses all effects.

const MobileSidebar = {
  mounted() {
    this._previousFocus = null;
    // Each entry: { el, hadInert, hadAriaHidden, ariaHiddenValue }
    this._inerted = [];
    this._active = false;
    this._trapHandler = null;

    this._mediaQuery = window.matchMedia("(max-width: 960px)");
    this._onMediaChangeBound = () => this._update();
    this._mediaQuery.addEventListener("change", this._onMediaChangeBound);

    // Check initial state (sidebar may already be expanded on mount)
    this._update();
  },

  updated() {
    this._update();
  },

  destroyed() {
    this._deactivate();
    if (this._mediaQuery) {
      this._mediaQuery.removeEventListener("change", this._onMediaChangeBound);
    }
  },

  _update() {
    const isMobile = this._mediaQuery.matches;
    const isExpanded = this.el.classList.contains("context-sidebar-expanded");

    if (isMobile && isExpanded) {
      this._activate();
    } else {
      this._deactivate();
    }
  },

  _activate() {
    if (this._active) return;
    this._active = true;

    // Store previously focused element (the mobile toggle or whatever had focus)
    if (!this._previousFocus || !document.contains(this._previousFocus)) {
      this._previousFocus = document.activeElement;
    }

    // Make background elements inert
    this._applyInert();

    // Install focus trap on the sidebar
    this._installTrap();

    // Move focus into the sidebar — prefer the "Hide sidebar" close button
    const hideBtn = this.el.querySelector(
      'button[phx-click="set_sidebar_state"][phx-value-state="hidden"]'
    );
    if (hideBtn) {
      // Small delay to let LiveView DOM settle after inert application
      setTimeout(() => hideBtn.focus(), 0);
    } else {
      const first = this._firstFocusable(this.el);
      if (first) setTimeout(() => first.focus(), 0);
    }
  },

  _deactivate() {
    if (!this._active) return;
    this._active = false;

    this._removeInert();
    this._uninstallTrap();

    // Restore focus to the mobile toggle button
    const toggle = document.querySelector(".mobile-sidebar-toggle");
    if (toggle && toggle.offsetParent !== null) {
      toggle.focus();
    } else if (this._previousFocus && document.contains(this._previousFocus)) {
      this._previousFocus.focus();
    }
    this._previousFocus = null;
  },

  _applyInert() {
    this._removeInert();

    const shell = document.getElementById("muse-shell");
    if (!shell) return;

    const sidebar = this.el;

    // Inert siblings of #main-content under #muse-shell
    for (const child of shell.children) {
      if (child === sidebar) continue;
      // Skip #main-content (it contains the sidebar) — we inert its children separately
      if (child.id === "main-content") continue;
      // Skip the backdrop — it must remain clickable for dismissal
      if (child.classList && child.classList.contains("mobile-sidebar-backdrop")) continue;

      if (!child.hasAttribute("inert")) {
        this._inertPush(child);
        child.setAttribute("inert", "");
        child.setAttribute("aria-hidden", "true");
      }
    }

    // Inert children of #main-content that are NOT the sidebar
    const mainContent = document.getElementById("main-content");
    if (mainContent) {
      for (const child of mainContent.children) {
        if (child === sidebar) continue;
        // Skip elements that are ancestors of the sidebar
        if (child.contains && child.contains(sidebar)) continue;

        if (!child.hasAttribute("inert")) {
          this._inertPush(child);
          child.setAttribute("inert", "");
          child.setAttribute("aria-hidden", "true");
        }
      }
    }
  },

  // Record pre-existing inert/aria-hidden state so we can restore precisely
  _inertPush(el) {
    this._inerted.push({
      el,
      hadInert: el.hasAttribute("inert"),
      hadAriaHidden: el.hasAttribute("aria-hidden"),
      ariaHiddenValue: el.getAttribute("aria-hidden")
    });
  },

  _removeInert() {
    for (const entry of this._inerted) {
      const { el, hadInert, hadAriaHidden, ariaHiddenValue } = entry;
      if (hadInert) {
        el.setAttribute("inert", "");
      } else {
        el.removeAttribute("inert");
      }
      if (hadAriaHidden) {
        el.setAttribute("aria-hidden", ariaHiddenValue || "true");
      } else {
        el.removeAttribute("aria-hidden");
      }
    }
    this._inerted = [];
  },

  _installTrap() {
    this._uninstallTrap();

    this._trapHandler = (e) => {
      if (e.key === "Tab") {
        this._handleTab(e);
      } else if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        this._closeSidebar();
      }
    };

    this.el.addEventListener("keydown", this._trapHandler);
  },

  _uninstallTrap() {
    if (this._trapHandler && this.el) {
      this.el.removeEventListener("keydown", this._trapHandler);
      this._trapHandler = null;
    }
  },

  _handleTab(e) {
    const focusables = this._focusables(this.el);
    if (focusables.length === 0) return;

    const first = focusables[0];
    const last = focusables[focusables.length - 1];

    if (e.shiftKey) {
      if (document.activeElement === first) {
        e.preventDefault();
        last.focus();
      }
    } else {
      if (document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
  },

  _closeSidebar() {
    this.pushEvent("set_sidebar_state", { state: "hidden" });
  },

  _focusables(el) {
    const sel = [
      'a[href]',
      'button:not([disabled])',
      'input:not([disabled])',
      'select:not([disabled])',
      'textarea:not([disabled])',
      '[tabindex]:not([tabindex="-1"])'
    ].join(',');
    return Array.from(el.querySelectorAll(sel)).filter(
      (e) => e.offsetParent !== null && !e.hasAttribute('inert')
    );
  },

  _firstFocusable(el) {
    const all = this._focusables(el);
    return all.length > 0 ? all[0] : null;
  }
};

// ─── DiagnosticsDrawer hook ───────────────────────────────────────
//
// Implements the WCAG modal dialog pattern for the diagnostics drawer.
// - Moves focus into the drawer on open
// - Traps Tab/Shift+Tab within drawer boundaries
// - Makes the rest of the page inert while the drawer is open
// - Escape key closes the drawer and restores focus to the trigger

const DiagnosticsDrawer = {
  mounted() {
    this._previousFocus = null;
    // Each entry: { el, hadInert, hadAriaHidden, ariaHiddenValue }
    this._inerted = [];

    // Activate the drawer: move focus in, make background inert, install trap
    this._activate();
  },

  destroyed() {
    this._deactivate();
  },

  updated() {
    // If LiveView re-renders while open, re-activate focus trap
    this._activate();
  },

  _activate() {
    const drawer = this.el;
    if (!drawer) return;

    // Store the previously focused element (the trigger button)
    if (!this._previousFocus || !document.contains(this._previousFocus)) {
      this._previousFocus = document.activeElement;
    }

    // Make siblings of the drawer inert (everything outside the drawer)
    this._applyInert(drawer);

    // Install focus trap
    this._installTrap(drawer);

    // Move focus into the drawer (close button or first focusable)
    const closeBtn = drawer.querySelector(".diagnostics-collapse-btn");
    if (closeBtn) {
      closeBtn.focus();
    } else {
      const first = this._firstFocusable(drawer);
      if (first) first.focus();
    }
  },

  _deactivate() {
    // Remove inert from background elements
    this._removeInert();

    // Uninstall focus trap
    this._uninstallTrap();

    // Restore focus to the trigger element
    if (this._previousFocus && document.contains(this._previousFocus)) {
      this._previousFocus.focus();
    }
    this._previousFocus = null;
  },

  _applyInert(drawer) {
    // Remove any previous inert first
    this._removeInert();

    // Mark all siblings of the drawer's parent as inert
    // The drawer is typically a direct child of the LiveView root
    const parent = drawer.parentElement;
    if (!parent) return;

    for (const child of parent.children) {
      if (child === drawer) continue;
      if (!child.hasAttribute("inert")) {
        this._inertPush(child);
        child.setAttribute("inert", "");
        child.setAttribute("aria-hidden", "true");
      }
    }
  },

  // Record pre-existing inert/aria-hidden state so we can restore precisely
  _inertPush(el) {
    this._inerted.push({
      el,
      hadInert: el.hasAttribute("inert"),
      hadAriaHidden: el.hasAttribute("aria-hidden"),
      ariaHiddenValue: el.getAttribute("aria-hidden")
    });
  },

  _removeInert() {
    for (const entry of this._inerted) {
      const { el, hadInert, hadAriaHidden, ariaHiddenValue } = entry;
      if (hadInert) {
        el.setAttribute("inert", "");
      } else {
        el.removeAttribute("inert");
      }
      if (hadAriaHidden) {
        el.setAttribute("aria-hidden", ariaHiddenValue || "true");
      } else {
        el.removeAttribute("aria-hidden");
      }
    }
    this._inerted = [];
  },

  _installTrap(drawer) {
    this._uninstallTrap();

    this._trapHandler = (e) => {
      if (e.key === "Tab") {
        this._handleTab(e, drawer);
      } else if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        // Close the drawer via Phoenix event and restore focus
        this._closeDrawer();
      }
    };

    drawer.addEventListener("keydown", this._trapHandler);
  },

  _uninstallTrap() {
    if (this._trapHandler && this.el) {
      this.el.removeEventListener("keydown", this._trapHandler);
      this._trapHandler = null;
    }
  },

  _handleTab(e, drawer) {
    const focusables = this._focusables(drawer);
    if (focusables.length === 0) return;

    const first = focusables[0];
    const last = focusables[focusables.length - 1];

    if (e.shiftKey) {
      // Shift+Tab: if on first element, wrap to last
      if (document.activeElement === first) {
        e.preventDefault();
        last.focus();
      }
    } else {
      // Tab: if on last element, wrap to first
      if (document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
  },

  _closeDrawer() {
    // Click the close button to trigger the Phoenix collapse_diagnostics event
    const closeBtn = this.el.querySelector(".diagnostics-collapse-btn");
    if (closeBtn) {
      closeBtn.click();
    }
  },

  _focusables(el) {
    const sel = [
      'a[href]',
      'button:not([disabled])',
      'input:not([disabled])',
      'select:not([disabled])',
      'textarea:not([disabled])',
      '[tabindex]:not([tabindex="-1"])'
    ].join(',');
    return Array.from(el.querySelectorAll(sel)).filter(
      (e) => e.offsetParent !== null && !e.hasAttribute('inert')
    );
  },

  _firstFocusable(el) {
    const all = this._focusables(el);
    return all.length > 0 ? all[0] : null;
  }
};

// ─── Hooks & LiveSocket ───────────────────────────────────────────

let Hooks = {
  DraggableWindow,
  CommandConsole,
  ToastAutoDismiss,
  KeyboardShortcuts,
  CommandPalette,
  MobileSidebar,
  DiagnosticsDrawer,
  ClipboardHandler
};

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {hooks: Hooks, params: {_csrf_token: csrfToken}})
liveSocket.connect()
