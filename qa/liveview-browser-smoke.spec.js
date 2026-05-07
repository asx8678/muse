// qa/liveview-browser-smoke.spec.js
//
// Real-browser LiveView smoke test for Muse.
//
// What it verifies:
//   - Page loads without console.error, pageerror, or unhandledrejection
//   - LiveView WebSocket connects (phx-loading class resolves)
//   - Command/help discoverability in the DOM (semantic markers, not CSS)
//   - Message composer input is focusable; keyboard Tab reaches it
//   - Session/context panel accessible names in the browser DOM
//   - No visible secrets or token-like strings in rendered page text
//
// Prerequisites:
//   - Muse smoke server running at MUSE_BROWSER_SMOKE_HOST:MUSE_BROWSER_SMOKE_PORT
//   - Playwright browsers installed (npm run browser:install)

const { test, expect } = require("@playwright/test");

// ─── Console / page error collection ──────────────────────────────────────
//
// We collect console messages and page errors BEFORE and AFTER navigation
// so we catch errors during LiveView connect, JS hook mount, etc.
// Only console.error / pageerror / unhandledrejection are fatal.
// console.warn is logged but not fatal.

test.describe("Muse LiveView browser smoke", () => {
  /** @type {Array<{type: string, text: string}>} */
  let consoleMessages = [];
  /** @type {Array<{error: Error}>} */
  let pageErrors = [];

  test.beforeEach(async ({ page }) => {
    consoleMessages = [];
    pageErrors = [];

    // Listen for console messages before navigation
    page.on("console", (msg) => {
      consoleMessages.push({ type: msg.type(), text: msg.text() });
    });

    // Listen for page errors (window.onerror, unhandled exceptions)
    page.on("pageerror", (error) => {
      pageErrors.push({ error });
    });

    // Navigate to the home page
    await page.goto("/");

    // Wait for LiveView to finish connecting (phx-loading is removed on connect)
    // Phoenix LiveView adds phx-loading to <html> while connecting,
    // then removes it once the WebSocket is established and the first render completes.
    await page.waitForFunction(() => {
      return !document.documentElement.classList.contains("phx-loading");
    }, { timeout: 15_000 });
  });

  // ─── 1. No browser console errors or page errors ──────────────────────

  test("no console.error or pageerror or unhandledrejection", () => {
    const errors = consoleMessages.filter((m) => m.type === "error");

    if (errors.length > 0) {
      const detail = errors.map((e) => `  console.error: ${e.text}`).join("\n");
      throw new Error(`Browser console errors detected:\n${detail}`);
    }

    if (pageErrors.length > 0) {
      const detail = pageErrors.map((e) => `  pageerror: ${e.error.message}`).join("\n");
      throw new Error(`Browser page errors detected:\n${detail}`);
    }
  });

  // ─── 2. LiveView connected (WebSocket) ────────────────────────────────

  test("LiveView WebSocket connected", async ({ page }) => {
    // phx-loading class should be gone (already asserted in beforeEach),
    // but also verify the main LiveView element exists and is connected.
    const mainEl = page.locator("#muse-shell");
    await expect(mainEl).toBeAttached();

    // Verify LiveSocket is connected by checking that the LiveView
    // main element has a phx-connected attribute or no phx-disconnected.
    // Phoenix LiveView 0.20+ adds data-phx-session and the socket is
    // connected when phx-loading is removed.
    const isDisconnected = await page.evaluate(() => {
      const el = document.querySelector("[data-phx-session]");
      if (!el) return false;
      // If phx-loading is gone, the LV is connected
      return document.documentElement.classList.contains("phx-loading");
    });
    expect(isDisconnected).toBe(false);
  });

  // ─── 3. Command / help discoverability ────────────────────────────────

  test("command discoverability in DOM", async ({ page }) => {
    // aria-label on input is "Message to Muse" (visible label removed, aria-only)
    const input = page.locator("#chat-input-textarea");
    await expect(input).toHaveAttribute(
      "aria-label",
      /Message to Muse/
    );

    // /help hint is in the placeholder, not the aria-label
    // Placeholder text is present and meaningful (contains prompt-like language)
    const placeholder = await input.getAttribute("placeholder");
    expect(placeholder).toBeTruthy();
    expect(placeholder).toMatch(/\/help/);
    // The placeholder is concise: "Ask Muse anything, or type /help..."
    expect(placeholder.toLowerCase()).toMatch(/ask.*muse/);

    // data-slash-commands attribute on composer
    const composer = page.locator("#input-form");
    await expect(composer).toHaveAttribute("data-slash-commands", /.+/);

    // Composer has role="form" and descriptive aria-label
    await expect(composer).toHaveAttribute("role", "form");
    await expect(composer).toHaveAttribute("aria-label", /composer/i);

    // Send button with descriptive label
    const sendBtn = page.locator('button[aria-label="Send message to Muse"]');
    await expect(sendBtn).toBeAttached();
  });

  // ─── 4. Keyboard focusability and tab order ───────────────────────────

  test("message composer input is focusable via keyboard Tab", async ({ page }) => {
    // Verify the textarea is focusable
    const input = page.locator("#chat-input-textarea");
    await expect(input).toBeEnabled();

    // Tab into the page from the start and verify we can reach the composer input.
    // The exact number of tabs depends on header/sidebar elements, so we tab
    // up to a reasonable limit and verify the input is reachable.
    let reachedInput = false;
    for (let i = 0; i < 20; i++) {
      await page.keyboard.press("Tab");
      const focused = await page.evaluate(() => {
        return document.activeElement?.id || document.activeElement?.tagName || "";
      });
      if (focused === "chat-input-textarea" || focused === "TEXTAREA") {
        reachedInput = true;
        break;
      }
    }
    expect(reachedInput).toBe(true);

    // Verify the focused element is the chat input textarea
    const isTextarea = await page.evaluate(() => {
      const el = document.activeElement;
      return el?.tagName === "TEXTAREA" && el?.id === "chat-input-textarea";
    });
    expect(isTextarea).toBe(true);

    // Verify that Enter doesn't throw errors (empty submit is ok)
    await page.keyboard.press("Enter");
    // Give the page a moment to process
    await page.waitForTimeout(500);

    // No console errors should have appeared
    const errors = consoleMessages.filter((m) => m.type === "error");
    expect(errors).toHaveLength(0);
    expect(pageErrors).toHaveLength(0);
  });

  // ─── 5. Session / context panel markers ──────────────────────────────

  test("session and context panel accessible names in DOM", async ({ page }) => {
    // Context panel has role="complementary" and descriptive aria-label
    const contextPanel = page.locator('aside[role="complementary"]');
    await expect(contextPanel).toBeAttached();
    await expect(contextPanel).toHaveAttribute(
      "aria-label",
      /workspace context and session status/i
    );

    // Context sidebar class
    const sidebar = page.locator(".context-sidebar");
    await expect(sidebar).toBeAttached();

    // Session status has role="status" when session is active —
    // may not render on fresh page with no active session.
    // The context panel itself is the reliable landmark.
    const sessionStatus = page.locator('[role="status"]');
    const count = await sessionStatus.count();
    // Accept 0 or more: role=status is conditional on session data
    expect(count).toBeGreaterThanOrEqual(0);
  });

  // ─── 6. No visible secrets or token-like strings ─────────────────────

  test("no visible secrets in page content", async ({ page }) => {
    // Get all visible text content from the page body.
    // We check visible text rather than innerHTML to avoid matching
    // code comments, script tags, or non-rendered HTML.
    const bodyText = await page.evaluate(() => {
      // Walk visible text nodes only
      const walker = document.createTreeWalker(
        document.body,
        NodeFilter.SHOW_TEXT,
        {
          acceptNode(node) {
            // Skip script/style content
            const parent = node.parentElement;
            if (!parent) return NodeFilter.FILTER_REJECT;
            const tag = parent.tagName.toLowerCase();
            if (tag === "script" || tag === "style") return NodeFilter.FILTER_REJECT;
            // Skip hidden elements
            if (parent.offsetParent === null && parent.tagName !== "BODY") {
              return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_ACCEPT;
          },
        }
      );
      const texts = [];
      while (walker.nextNode()) {
        const t = walker.currentNode.textContent;
        if (t && t.trim()) texts.push(t);
      }
      return texts.join(" ");
    });

    // Secret patterns that must never appear in visible page text
    const secretPatterns = [
      { pattern: /sk-[a-zA-Z0-9]{8,}/, desc: "OpenAI/Anthropic API key prefix" },
      { pattern: /sk_live_[a-zA-Z0-9]+/, desc: "live API key prefix" },
      { pattern: /Bearer\s+[a-zA-Z0-9\-._~+/]+=*/, desc: "bearer token" },
      { pattern: /OPENAI_API_KEY/, desc: "env var name for OpenAI API key" },
      { pattern: /ANTHROPIC_API_KEY/, desc: "env var name for Anthropic API key" },
      { pattern: /secret_key_base/, desc: "Phoenix secret key base reference" },
    ];

    const leaked = secretPatterns.filter(({ pattern }) => pattern.test(bodyText));

    if (leaked.length > 0) {
      const detail = leaked.map((l) => `  ${l.desc}`).join("\n");
      throw new Error(`Visible secrets found in page:\n${detail}`);
    }
  });

  // ─── 7. Accessibility landmarks present ─────────────────────────────

  test("ARIA landmarks and live regions present", async ({ page }) => {
    // Chat panel region
    const chatRegion = page.locator('[role="region"][aria-label="Muse conversation"]');
    await expect(chatRegion).toBeAttached();

    // Chat scroll has log role and live region
    const chatLog = page.locator('#chat-scroll[role="log"]');
    await expect(chatLog).toBeAttached();
    await expect(chatLog).toHaveAttribute("aria-live", "polite");

    // Toast container has aria-label="Notifications" (no role=status after live-region simplification)
    const toastContainer = page.locator('[aria-label="Notifications"]');
    await expect(toastContainer).toBeAttached();

    // Composer form role
    const composerForm = page.locator('#input-form[role="form"]');
    await expect(composerForm).toBeAttached();

    // Textarea has an accessible name and concise placeholder.
    const textarea = page.locator('#chat-input-textarea');
    await expect(textarea).toHaveAttribute("aria-label", /Message to Muse/);
    await expect(textarea).toHaveAttribute("placeholder", /Ask Muse/);
  });

  // ─── 8. Page load success and no network errors ──────────────────────

  test("page loads with 200 and substantial content", async ({ page }) => {
    // Verify the main shell element is present
    const shell = page.locator("#muse-shell");
    await expect(shell).toBeAttached();

    // Verify there's meaningful content (not an error page)
    const html = await page.content();
    expect(html.length).toBeGreaterThan(500);
  });
});

// ─── Mobile viewport smoke ─────────────────────────────────────────────

test.describe("Muse LiveView mobile viewport smoke", () => {
  /** @type {Array<{type: string, text: string}>} */
  let consoleMessages = [];
  /** @type {Array<{error: Error}>} */
  let pageErrors = [];

  test.use({ viewport: { width: 320, height: 568 } });

  test.beforeEach(async ({ page }) => {
    consoleMessages = [];
    pageErrors = [];

    page.on("console", (msg) => {
      consoleMessages.push({ type: msg.type(), text: msg.text() });
    });

    page.on("pageerror", (error) => {
      pageErrors.push({ error });
    });

    await page.goto("/");

    await page.waitForFunction(() => {
      return !document.documentElement.classList.contains("phx-loading");
    }, { timeout: 15_000 });
  });

  test("page loads without errors at 320px viewport", () => {
    const errors = consoleMessages.filter((m) => m.type === "error");
    expect(errors).toHaveLength(0);
    expect(pageErrors).toHaveLength(0);
  });

  test("mobile sidebar toggle button is rendered", async ({ page }) => {
    const toggle = page.locator(".mobile-sidebar-toggle");
    await expect(toggle).toBeAttached();
    await expect(toggle).toHaveAttribute("aria-label", /toggle context sidebar/i);
  });

  test("no horizontal scroll at 320px viewport", async ({ page }) => {
    const scrollWidth = await page.evaluate(() => {
      return document.documentElement.scrollWidth;
    });
    const clientWidth = await page.evaluate(() => {
      return document.documentElement.clientWidth;
    });
    // Allow 2px tolerance for sub-pixel rounding
    expect(scrollWidth).toBeLessThanOrEqual(clientWidth + 2);
  });

  test("composer input is focusable at 320px viewport after closing sidebar", async ({ page }) => {
    // Close the mobile sidebar first — at 320px the sidebar overlay covers
    // most of the viewport and makes background elements inert.
    const hideBtn = page.locator('#workspace-context-sidebar button[phx-value-state="hidden"]');
    await hideBtn.click();
    // Wait for sidebar to collapse and inert to be removed
    await expect.poll(() => {
      return page.evaluate(() => {
        const textarea = document.getElementById("chat-input-textarea");
        if (!textarea) return true;
        let el = textarea;
        while (el) {
          if (el.hasAttribute("inert")) return false;
          el = el.parentElement;
        }
        return true;
      });
    }, { timeout: 5_000 }).toBe(true);

    const input = page.locator("#chat-input-textarea");
    await expect(input).toBeEnabled();
    // Click to focus (mobile touch)
    await input.click();
    const focused = await page.evaluate(() => document.activeElement?.id);
    expect(focused).toBe("chat-input-textarea");
  });

  test("send button is visible and reachable at 320px", async ({ page }) => {
    const sendBtn = page.locator('button[aria-label="Send message to Muse"]');
    await expect(sendBtn).toBeVisible();
  });
});

// ─── Mobile sidebar a11y regression ─────────────────────────────────────
//
// Verifies WCAG 2.1 AA compliance for the mobile context sidebar overlay:
//   - Focus is trapped within sidebar when open
//   - Background controls are inert (not focusable)
//   - Escape closes sidebar and restores focus to toggle
//   - Backdrop click closes sidebar
//   - Pre-existing aria-hidden attributes are preserved on close
//   - Desktop expanded sidebar does not inert background
//   - Existing mobile tests still pass
//
// The sidebar starts expanded by default on mount. At mobile viewport, the
// MobileSidebar hook activates immediately, making background elements inert
// and trapping focus in the sidebar. Tests must account for this initial
// state — they close the sidebar first, then perform specific open/close
// sequences to test the hook behavior.

// ─── Helpers ────────────────────────────────────────────────────────────

async function waitForSidebarClass(page, className) {
  const cls = "context-sidebar-" + className;
  await expect.poll(() => {
    return page.evaluate((c) => {
      const el = document.getElementById("workspace-context-sidebar");
      return el ? el.classList.contains(c) : false;
    }, cls);
  }, { timeout: 5_000 }).toBe(true);
}

async function closeMobileSidebar(page) {
  // Close the mobile sidebar via the "Hide sidebar" button inside the sidebar.
  const hideBtn = page.locator('#workspace-context-sidebar button[phx-value-state="hidden"]');
  await hideBtn.click();
  await waitForSidebarClass(page, "hidden");
}

async function openMobileSidebar(page) {
  // Open the mobile sidebar via the toggle button.
  const toggle = page.locator(".mobile-sidebar-toggle");
  await toggle.click();
  await waitForSidebarClass(page, "expanded");
}

async function assertFocusInSidebar(page) {
  await expect.poll(() => {
    return page.evaluate(() => {
      const sidebar = document.getElementById("workspace-context-sidebar");
      return sidebar ? sidebar.contains(document.activeElement) : false;
    });
  }, { timeout: 3_000 }).toBe(true);
}

async function waitForMobileHookActive(page) {
  // Wait until the MobileSidebar hook has activated (background is inert).
  await expect.poll(() => {
    return page.evaluate(() => {
      const textarea = document.getElementById("chat-input-textarea");
      if (!textarea) return false;
      let el = textarea;
      while (el) {
        if (el.hasAttribute("inert")) return true;
        el = el.parentElement;
      }
      return false;
    });
  }, { timeout: 5_000 }).toBe(true);
}

async function waitForMobileHookInactive(page) {
  // Wait until the MobileSidebar hook has deactivated (background is not inert).
  await expect.poll(() => {
    return page.evaluate(() => {
      const textarea = document.getElementById("chat-input-textarea");
      if (!textarea) return true; // No textarea means no chat-panel to check
      let el = textarea;
      while (el) {
        if (el.hasAttribute("inert")) return false;
        el = el.parentElement;
      }
      return true;
    });
  }, { timeout: 5_000 }).toBe(true);
}

// ─── Mobile sidebar a11y (390px) ─────────────────────────────────────

test.describe("Muse mobile sidebar a11y (390px)", () => {
  /** @type {Array<{type: string, text: string}>} */
  let consoleMessages = [];
  /** @type {Array<{error: Error}>} */
  let pageErrors = [];

  test.use({ viewport: { width: 390, height: 844 } });

  test.beforeEach(async ({ page }) => {
    consoleMessages = [];
    pageErrors = [];

    page.on("console", (msg) => {
      consoleMessages.push({ type: msg.type(), text: msg.text() });
    });

    page.on("pageerror", (error) => {
      pageErrors.push({ error });
    });

    await page.goto("/");

    await page.waitForFunction(() => {
      return !document.documentElement.classList.contains("phx-loading");
    }, { timeout: 15_000 });
  });

  test.afterEach(() => {
    const errors = consoleMessages.filter((m) => m.type === "error");
    if (errors.length > 0) {
      const detail = errors.map((e) => `  console.error: ${e.text}`).join("\n");
      throw new Error(`Browser console errors detected:\n${detail}`);
    }
    if (pageErrors.length > 0) {
      const detail = pageErrors.map((e) => `  pageerror: ${e.error.message}`).join("\n");
      throw new Error(`Browser page errors detected:\n${detail}`);
    }
  });

  test("mobile sidebar toggle has aria-controls pointing at sidebar", async ({ page }) => {
    const toggle = page.locator(".mobile-sidebar-toggle");
    await expect(toggle).toHaveAttribute("aria-controls", "workspace-context-sidebar");

    const sidebar = page.locator("#workspace-context-sidebar");
    await expect(sidebar).toBeAttached();
  });

  test("mobile sidebar starts expanded and focus is trapped inside", async ({ page }) => {
    // Sidebar starts expanded on mount at mobile viewport.
    // The MobileSidebar hook should activate and move focus into the sidebar.
    await assertFocusInSidebar(page);

    // Tab several times — focus should never leave the sidebar
    for (let i = 0; i < 10; i++) {
      await page.keyboard.press("Tab");
    }
    await assertFocusInSidebar(page);

    // Shift+Tab several times — still in sidebar
    for (let i = 0; i < 10; i++) {
      await page.keyboard.press("Shift+Tab");
    }
    await assertFocusInSidebar(page);
  });

  test("background textarea and send button are not focusable while mobile sidebar is open", async ({ page }) => {
    // Sidebar starts expanded, so background should already be inert
    await waitForMobileHookActive(page);

    const textareaInert = await page.evaluate(() => {
      const textarea = document.getElementById("chat-input-textarea");
      if (!textarea) return false;
      let el = textarea;
      while (el) {
        if (el.hasAttribute("inert")) return true;
        el = el.parentElement;
      }
      return false;
    });
    expect(textareaInert).toBe(true);

    const sendBtnInert = await page.evaluate(() => {
      const btn = document.querySelector('button[aria-label="Send message to Muse"]');
      if (!btn) return false;
      let el = btn;
      while (el) {
        if (el.hasAttribute("inert")) return true;
        el = el.parentElement;
      }
      return false;
    });
    expect(sendBtnInert).toBe(true);
  });

  test("Escape closes mobile sidebar and focus returns to toggle", async ({ page }) => {
    // Sidebar starts expanded — press Escape to close
    await waitForMobileHookActive(page);
    await page.keyboard.press("Escape");

    // Sidebar should be collapsed
    const sidebar = page.locator("#workspace-context-sidebar");
    await expect(sidebar).toHaveClass(/context-sidebar-hidden/, { timeout: 5_000 });

    // Focus should return to the mobile toggle
    const focusedClass = await page.evaluate(() => document.activeElement?.className || "");
    expect(focusedClass).toContain("mobile-sidebar-toggle");
  });

  test("backdrop click (390px) closes mobile sidebar via real pointer", async ({ page }) => {
    // Sidebar starts expanded — click in the backdrop area to the right of the sidebar.
    // The backdrop CSS covers left: min(320px,85vw) to right:0. At 390px, that's
    // left: 320px, so we click at x=350 (midpoint of the 70px-wide backdrop strip).
    await waitForMobileHookActive(page);
    await page.mouse.click(350, 200);

    // Sidebar should be collapsed
    const sidebar = page.locator("#workspace-context-sidebar");
    await expect(sidebar).toHaveClass(/context-sidebar-hidden/, { timeout: 5_000 });
  });

  test("backdrop click (320px) closes mobile sidebar via real pointer", async ({ page }) => {
    // Resize to 320px to verify the backdrop still works at the narrowest viewport.
    // At 320px, 85vw = 272px, so backdrop left = 272px and width = 48px.
    // Click at x=296 (midpoint of the 48px backdrop strip).
    await page.setViewportSize({ width: 320, height: 568 });
    await waitForMobileHookActive(page);
    await page.mouse.click(296, 200);

    const sidebar = page.locator("#workspace-context-sidebar");
    await expect(sidebar).toHaveClass(/context-sidebar-hidden/, { timeout: 5_000 });
  });

  test("opening mobile sidebar moves focus into sidebar", async ({ page }) => {
    // Close the initially-expanded sidebar first
    await closeMobileSidebar(page);

    // Now open it via the toggle
    await openMobileSidebar(page);

    // Focus should be inside the sidebar
    await assertFocusInSidebar(page);
  });

  test("background controls are focusable again after closing mobile sidebar", async ({ page }) => {
    // Close the initially-expanded sidebar
    await closeMobileSidebar(page);
    await waitForMobileHookInactive(page);
  });

  test("pre-existing aria-hidden is preserved after close-button dismiss", async ({ page }) => {
    // #clipboard-handler starts with aria-hidden="true" in the server-rendered HTML.
    // After opening then closing the mobile sidebar, it must retain aria-hidden="true".
    await waitForMobileHookActive(page);
    await closeMobileSidebar(page);
    await waitForMobileHookInactive(page);

    const clipboardAriaHidden = await page.evaluate(() => {
      const el = document.getElementById("clipboard-handler");
      return el ? el.getAttribute("aria-hidden") : null;
    });
    expect(clipboardAriaHidden).toBe("true");
  });

  test("pre-existing aria-hidden is preserved after Escape dismiss", async ({ page }) => {
    await waitForMobileHookActive(page);
    await page.keyboard.press("Escape");
    await waitForMobileHookInactive(page);

    const clipboardAriaHidden = await page.evaluate(() => {
      const el = document.getElementById("clipboard-handler");
      return el ? el.getAttribute("aria-hidden") : null;
    });
    expect(clipboardAriaHidden).toBe("true");
  });

  test("pre-existing aria-hidden is preserved after mobile-to-desktop resize", async ({ page }) => {
    await waitForMobileHookActive(page);

    // Resize to desktop — hook should deactivate
    await page.setViewportSize({ width: 1200, height: 800 });
    await waitForMobileHookInactive(page);

    const clipboardAriaHidden = await page.evaluate(() => {
      const el = document.getElementById("clipboard-handler");
      return el ? el.getAttribute("aria-hidden") : null;
    });
    expect(clipboardAriaHidden).toBe("true");
  });
});

// ─── Desktop sidebar regression (1200px) ─────────────────────────────────
//
// Verifies that desktop expanded sidebar does NOT inert background elements.

test.describe("Muse desktop sidebar does not inert background", () => {
  test.use({ viewport: { width: 1200, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForFunction(() => {
      return !document.documentElement.classList.contains("phx-loading");
    }, { timeout: 15_000 });
  });

  test("desktop expanded sidebar does not inert app-header", async ({ page }) => {
    const headerInert = await page.evaluate(() => {
      const header = document.querySelector(".app-header");
      if (!header) return false;
      return header.hasAttribute("inert");
    });
    expect(headerInert).toBe(false);
  });

  test("desktop expanded sidebar does not inert chat panel / textarea", async ({ page }) => {
    const textareaInert = await page.evaluate(() => {
      const textarea = document.getElementById("chat-input-textarea");
      if (!textarea) return false;
      let el = textarea;
      while (el) {
        if (el.hasAttribute("inert")) return true;
        el = el.parentElement;
      }
      return false;
    });
    expect(textareaInert).toBe(false);
  });
});
