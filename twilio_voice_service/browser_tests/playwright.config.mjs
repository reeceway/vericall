import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "@playwright/test";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const serviceRoot = path.resolve(__dirname, "..");
const pythonBin =
  process.env.VICALL_PYTHON_BIN ||
  path.resolve(serviceRoot, ".venv-codex-msp", "bin", "python");
const harnessScript = path.resolve(serviceRoot, "scripts", "msp_browser_test_harness.py");

export default defineConfig({
  testDir: path.resolve(__dirname, "tests"),
  fullyParallel: false,
  workers: 1,
  timeout: 120000,
  reporter: [["list"]],
  use: {
    baseURL: process.env.MSP_BROWSER_BASE_URL || "http://127.0.0.1:8091",
    headless: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure"
  },
  projects: [
    {
      name: "desktop",
      use: {
        viewport: { width: 1440, height: 960 }
      }
    },
    {
      name: "tablet",
      use: {
        viewport: { width: 1024, height: 1366 }
      }
    }
  ],
  webServer: {
    command: `"${pythonBin}" "${harnessScript}"`,
    cwd: serviceRoot,
    port: 8091,
    reuseExistingServer: true,
    timeout: 120000,
    env: {
      PORT: "8091",
      HOST: "127.0.0.1",
      PUBLIC_BASE_URL: process.env.MSP_BROWSER_BASE_URL || "http://127.0.0.1:8091",
      VICALL_ADMIN_API_KEY: process.env.VICALL_ADMIN_API_KEY || "test-admin-key",
      STRIPE_WEBHOOK_SECRET: process.env.STRIPE_WEBHOOK_SECRET || "whsec_browser_local",
      VICALL_BROWSER_TEST_OTP: process.env.VICALL_BROWSER_TEST_OTP || "111111"
    }
  }
});
