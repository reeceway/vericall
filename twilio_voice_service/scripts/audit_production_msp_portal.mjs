#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline/promises';
import process from 'node:process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const serviceRoot = resolve(__dirname, '..');
const browserTestsRoot = resolve(serviceRoot, 'browser_tests');
const requireFromBrowserTests = createRequire(resolve(browserTestsRoot, 'package.json'));
const { chromium } = requireFromBrowserTests('@playwright/test');

const args = new Set(process.argv.slice(2));
const baseUrl = process.env.VICALL_PORTAL_BASE_URL || 'https://vericall-twilio-voice.fly.dev';
const email = process.env.VICALL_PORTAL_EMAIL || 'reece@vicallapp.com';
const phone = process.env.VICALL_PORTAL_PHONE || '4128628887';
const outDir = process.env.VICALL_PORTAL_AUDIT_DIR || '/tmp/vicall-portal-audit';
const headed = args.has('--headed');
const otpFromMessages = args.has('--otp-from-messages') || process.env.VICALL_PORTAL_OTP_SOURCE === 'messages';
let otpRequestStartedAtMs = null;

function readPassword() {
  if (process.env.VICALL_PORTAL_PASSWORD) {
    return process.env.VICALL_PORTAL_PASSWORD.trim();
  }
  try {
    return execFileSync('/usr/bin/pbpaste', { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function messagesEpochNanoseconds(ms) {
  const secondsSinceUnixEpoch = Math.floor(ms / 1000);
  const secondsSinceMessagesEpoch = secondsSinceUnixEpoch - 978307200;
  return BigInt(secondsSinceMessagesEpoch) * 1000000000n;
}

function latestOtpFromMessages(sinceMs) {
  const dbPath = `${process.env.HOME}/Library/Messages/chat.db`;
  const sinceNs = messagesEpochNanoseconds(sinceMs).toString();
  const sql = `
    SELECT text
    FROM message
    WHERE is_from_me = 0
      AND text IS NOT NULL
      AND date >= ${sinceNs}
    ORDER BY date DESC
    LIMIT 50;
  `;
  let output = '';
  try {
    output = execFileSync('/usr/bin/sqlite3', ['-readonly', dbPath, sql], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch {
    return null;
  }
  for (const line of output.split(/\r?\n/)) {
    if (!/code|verify|verification|Vicall|VeriCall|Twilio/i.test(line)) {
      continue;
    }
    const match = line.match(/\b(\d{6})\b/);
    if (match) {
      return match[1];
    }
  }
  return null;
}

async function promptOtp() {
  if (process.env.VICALL_PORTAL_OTP) {
    return process.env.VICALL_PORTAL_OTP.trim();
  }
  if (otpFromMessages) {
    const sinceMs = (otpRequestStartedAtMs || Date.now()) - 15_000;
    const deadline = Date.now() + 75_000;
    while (Date.now() < deadline) {
      const otp = latestOtpFromMessages(sinceMs);
      if (otp) {
        console.log('OTP_FROM_MESSAGES_READY');
        return otp;
      }
      await sleep(2500);
    }
    throw new Error('No fresh production MSP SMS OTP found in Messages.');
  }
  if (!process.stdin.isTTY) {
    throw new Error('OTP required. Re-run with VICALL_PORTAL_OTP or from a TTY.');
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const otp = (await rl.question('Enter production MSP SMS OTP: ')).trim();
  rl.close();
  return otp;
}

async function firstVisible(locator) {
  const count = await locator.count().catch(() => 0);
  for (let i = 0; i < count; i += 1) {
    const candidate = locator.nth(i);
    if (await candidate.isVisible().catch(() => false)) {
      return candidate;
    }
  }
  return null;
}

async function fillFirst(page, selectors, value) {
  for (const selector of selectors) {
    const field = await firstVisible(page.locator(selector));
    if (field) {
      await field.fill(value);
      return selector;
    }
  }
  throw new Error(`No visible field found for ${selectors.join(', ')}`);
}

async function clickContinue(page) {
  const locators = [
    page.getByRole('button', { name: 'Continue' }),
    page.getByRole('button', { name: 'Text Me a Code' }),
    page.getByRole('button', { name: 'Sign In' }),
    page.locator('button[type="submit"]'),
    page.locator('input[type="submit"]'),
  ];
  for (const locator of locators) {
    const button = await firstVisible(locator);
    if (button && await button.isEnabled().catch(() => true)) {
      await button.click({ noWaitAfter: true });
      return;
    }
  }
  throw new Error('No visible submit button found.');
}

async function settleAfterSubmit(page, expectedPath = null) {
  if (expectedPath) {
    await page.waitForURL((url) => url.pathname.includes(expectedPath), { timeout: 15000 }).catch(() => {});
  }
  await page.waitForLoadState('domcontentloaded').catch(() => {});
  await page.waitForLoadState('networkidle').catch(() => {});
}

async function snapshot(page, label, results) {
  const screenshotPath = `${outDir}/${label}.png`;
  const textPath = `${outDir}/${label}.txt`;
  await page.screenshot({ path: screenshotPath, fullPage: true });
  const text = (await page.locator('body').innerText({ timeout: 5000 }).catch(() => '')).replace(/\s+/g, ' ').trim();
  const url = page.url();
  const title = await page.title().catch(() => '');
  writeFileSync(textPath, `URL ${url}\nTITLE ${title}\nTEXT ${text}\n`);
  results.pages.push({ label, url, title, screenshotPath, textPath, excerpt: text.slice(0, 500) });
  console.log(`CAPTURE ${label} ${url}`);
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  const password = readPassword();
  if (!password) {
    throw new Error('Portal password is missing from VICALL_PORTAL_PASSWORD and the macOS clipboard.');
  }

  const results = {
    ok: false,
    baseUrl,
    email,
    phoneSuffix: phone.slice(-4),
    outDir,
    pages: [],
    checks: {},
  };

  const browser = await chromium.launch({ headless: !headed });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
  const page = await context.newPage();
  page.setDefaultTimeout(15000);

  try {
    await page.goto(`${baseUrl}/portal/login`, { waitUntil: 'domcontentloaded' });
    await snapshot(page, '01-login', results);

    await fillFirst(page, ['input[name="email"]', 'input[type="email"]', 'input[autocomplete="username"]'], email);
    await fillFirst(page, ['input[name="password"]', 'input[type="password"]', 'input[autocomplete="current-password"]'], password);
    await clickContinue(page);
    await settleAfterSubmit(page, '/portal/login/phone');
    await snapshot(page, '02-after-credentials', results);

    if (await page.locator('input[name*="phone"], input[type="tel"]').count().catch(() => 0)) {
      await fillFirst(page, ['input[name="phone_number"]', 'input[name="phone"]', 'input[type="tel"]'], phone);
      otpRequestStartedAtMs = Date.now();
      await clickContinue(page);
      await settleAfterSubmit(page, '/portal/login/code');
      await snapshot(page, '03-after-phone', results);
    }

    if (await page.locator('input[name*="code"], input[autocomplete="one-time-code"]').count().catch(() => 0)) {
      console.log(`OTP_REQUIRED SMS sent to phone ending ${phone.slice(-4)}.`);
      const otp = await promptOtp();
      if (!/^\d{4,8}$/.test(otp)) {
        throw new Error('OTP format invalid.');
      }
      await fillFirst(page, ['input[name="code"]', 'input[name="otp"]', 'input[autocomplete="one-time-code"]'], otp);
      await clickContinue(page);
      await settleAfterSubmit(page, '/portal/dashboard');
      await snapshot(page, '04-after-otp', results);
    }

    if (!page.url().includes('/portal/dashboard')) {
      await page.goto(`${baseUrl}/portal/dashboard`, { waitUntil: 'domcontentloaded' });
      await page.waitForLoadState('networkidle').catch(() => {});
    }
    await snapshot(page, '05-dashboard', results);

    for (const [label, path] of [['billing', '/portal/billing'], ['audit', '/portal/audit']]) {
      await page.goto(`${baseUrl}${path}`, { waitUntil: 'domcontentloaded' });
      await page.waitForLoadState('networkidle').catch(() => {});
      await snapshot(page, `06-${label}`, results);
    }

    const allText = results.pages.map((pageResult) => pageResult.excerpt).join(' ');
    results.checks.loginCompleted = results.pages.some((pageResult) => pageResult.url.includes('/portal/dashboard'));
    results.checks.dashboardVisible = results.pages.some(
      (pageResult) => pageResult.label === '05-dashboard'
        && pageResult.url.includes('/portal/dashboard')
        && /Customer Companies|Billable Seats|Projected Monthly Bill/i.test(pageResult.excerpt)
    );
    results.checks.billingVisible = results.pages.some(
      (pageResult) => pageResult.label === '06-billing'
        && pageResult.url.includes('/portal/billing')
        && /Billing|Invoice|Overage|Included/i.test(pageResult.excerpt)
    );
    results.checks.auditVisible = results.pages.some(
      (pageResult) => pageResult.label === '06-audit'
        && pageResult.url.includes('/portal/audit')
        && /Audit|Event|Actor|Action/i.test(pageResult.excerpt)
    );
    results.ok = Object.values(results.checks).every(Boolean);
  } finally {
    await browser.close();
  }

  const resultPath = `${outDir}/portal-audit-result.json`;
  writeFileSync(resultPath, `${JSON.stringify(results, null, 2)}\n`);
  console.log(`RESULT ${resultPath}`);
  console.log(JSON.stringify({ ok: results.ok, checks: results.checks, outDir }, null, 2));
  if (!results.ok) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(`AUDIT_FAILED ${error.message}`);
  process.exit(1);
});
