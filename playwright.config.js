// playwright.config.js
//
// Playwright configuration for Muse LiveView browser smoke tests.
//
// Usage:
//   npm run smoke:liveview:browser
//   npx playwright test
//
// Prerequisites:
//   1. Muse smoke server running:
//      MIX_ENV=smoke MUSE_PROVIDER=fake mix muse --web-only --port 4101 --no-watch
//   2. Playwright browsers installed:
//      npm install
//      npm run browser:install
//
// Or use the orchestration script:
//      ./script/liveview-browser-smoke-playwright

const { defineConfig } = require("@playwright/test");

const port = process.env.MUSE_BROWSER_SMOKE_PORT || "4101";
const host = process.env.MUSE_BROWSER_SMOKE_HOST || "127.0.0.1";
const baseURL = `http://${host}:${port}`;

module.exports = defineConfig({
  testDir: "./qa",
  testMatch: "**/*.spec.js",
  timeout: 30_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL,
    headless: true,
    // Capture artifacts on failure only
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
  // Do NOT auto-start the web server here; the orchestration script handles it.
  // This config assumes the server is already running at baseURL.
});
