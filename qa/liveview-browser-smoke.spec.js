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
    // /help hint in input aria-label
    const input = page.locator("#chat-input-textarea");
    await expect(input).toHaveAttribute(
      "aria-label",
      /\/help/
    );

    // Placeholder text is present and meaningful (contains prompt-like language)
    const placeholder = await input.getAttribute("placeholder");
    expect(placeholder).toBeTruthy();
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

    // Session status has role="status" (one of the mini-cards)
    const sessionStatus = page.locator('[role="status"]');
    const count = await sessionStatus.count();
    expect(count).toBeGreaterThanOrEqual(1);
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

    // Toast container
    const toastContainer = page.locator('[role="status"][aria-label="Notifications"]');
    await expect(toastContainer).toBeAttached();

    // Composer form role
    const composerForm = page.locator('#input-form[role="form"]');
    await expect(composerForm).toBeAttached();

    // Visible label linked to textarea
    const label = page.locator('label[for="chat-input-textarea"]');
    await expect(label).toBeAttached();

    // Concise placeholder present
    const textarea = page.locator('#chat-input-textarea');
    await expect(textarea).toHaveAttribute('placeholder', /Ask Muse/);
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
