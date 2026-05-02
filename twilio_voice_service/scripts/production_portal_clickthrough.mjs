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

const baseUrl = process.env.VICALL_PORTAL_BASE_URL || 'https://vericall-twilio-voice.fly.dev';
const email = process.env.VICALL_PORTAL_EMAIL || 'reece@vicallapp.com';
const phone = process.env.VICALL_PORTAL_PHONE || '4128628887';
const outDir = process.env.VICALL_PORTAL_CLICKTHROUGH_DIR || `/tmp/vicall-portal-clickthrough-${Date.now()}`;
const headed = process.argv.includes('--headed');

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

async function promptOtp() {
  if (process.env.VICALL_PORTAL_OTP) {
    return process.env.VICALL_PORTAL_OTP.trim();
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
      return;
    }
  }
  throw new Error(`No visible field found for ${selectors.join(', ')}`);
}

async function clickFirst(page, locators) {
  for (const locator of locators) {
    const button = await firstVisible(locator);
    if (button && await button.isEnabled().catch(() => true)) {
      await button.click({ noWaitAfter: true });
      return true;
    }
  }
  return false;
}

async function clickSubmit(page) {
  const clicked = await clickFirst(page, [
    page.getByRole('button', { name: 'Continue' }),
    page.getByRole('button', { name: 'Text Me a Code' }),
    page.getByRole('button', { name: 'Sign In' }),
    page.locator('button[type="submit"]'),
    page.locator('input[type="submit"]'),
  ]);
  if (!clicked) {
    throw new Error('No visible submit button found.');
  }
}

async function settle(page, expectedPath = null) {
  if (expectedPath) {
    await page.waitForURL((url) => url.pathname.includes(expectedPath), { timeout: 20000 }).catch(() => {});
  }
  await page.waitForLoadState('domcontentloaded').catch(() => {});
  await page.waitForLoadState('networkidle').catch(() => {});
}

async function snapshot(page, label, results) {
  const screenshotPath = `${outDir}/${label}.png`;
  const textPath = `${outDir}/${label}.txt`;
  await page.screenshot({ path: screenshotPath, fullPage: true });
  const text = (await page.locator('body').innerText({ timeout: 7000 }).catch(() => '')).replace(/\s+/g, ' ').trim();
  const url = page.url();
  writeFileSync(textPath, `URL ${url}\nTEXT ${text}\n`);
  results.pages.push({ label, url, screenshotPath, textPath, excerpt: text.slice(0, 900) });
  console.log(`CAPTURE ${label} ${url}`);
}

async function metricText(page, label) {
  const body = await page.locator('body').innerText().catch(() => '');
  const compact = body.replace(/\s+/g, ' ');
  const index = compact.toLowerCase().indexOf(label.toLowerCase());
  if (index < 0) return null;
  return compact.slice(index, index + 140);
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
    metrics: {},
  };

  const browser = await chromium.launch({ headless: !headed });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);

  try {
    await page.goto(`${baseUrl}/portal/login`, { waitUntil: 'domcontentloaded' });
    await snapshot(page, '01-login', results);

    await fillFirst(page, ['input[name="email"]', 'input[type="email"]'], email);
    await fillFirst(page, ['input[name="password"]', 'input[type="password"]'], password);
    await clickSubmit(page);
    await settle(page, '/portal/login/phone');
    await snapshot(page, '02-phone-confirmation', results);

    await fillFirst(page, ['input[name="phone_number"]', 'input[name="phone"]', 'input[type="tel"]'], phone);
    await clickSubmit(page);
    await settle(page, '/portal/login/code');
    await snapshot(page, '03-code-entry', results);

    console.log(`OTP_REQUIRED SMS sent to phone ending ${phone.slice(-4)}.`);
    const otp = await promptOtp();
    if (!/^\d{4,8}$/.test(otp)) {
      throw new Error('OTP format invalid.');
    }
    await fillFirst(page, ['input[name="otp"]', 'input[name="code"]', 'input[autocomplete="one-time-code"]'], otp);
    await clickSubmit(page);
    await settle(page, '/portal/dashboard');
    await snapshot(page, '04-dashboard', results);

    results.metrics.dashboardCustomerCompanies = await metricText(page, 'Customer Companies');
    results.metrics.dashboardBillableSeats = await metricText(page, 'Billable Seats');
    results.metrics.dashboardUsedMinutes = await metricText(page, 'Used / Included Minutes');
    results.metrics.dashboardProjectedBill = await metricText(page, 'Projected Monthly Bill');

    const companyCards = page.locator('details.company-card');
    results.metrics.companyCardCount = await companyCards.count().catch(() => 0);
    if (results.metrics.companyCardCount > 0) {
      await companyCards.first().locator('summary').click();
      await settle(page);
      await snapshot(page, '05-dashboard-first-company-expanded', results);
    }

    await clickFirst(page, [
      page.getByRole('link', { name: /Open Billing Center/i }),
      page.locator('a[href="/portal/billing"]'),
    ]);
    await settle(page, '/portal/billing');
    await snapshot(page, '06-billing-center', results);
    results.metrics.billingSelectedPeriod = await metricText(page, 'Selected Period');
    results.metrics.billingCompanyRollup = await metricText(page, 'Company Rollup');
    results.metrics.billingUserUsage = await metricText(page, 'User Usage');

    await page.goto(`${baseUrl}/portal/audit`, { waitUntil: 'domcontentloaded' });
    await settle(page, '/portal/audit');
    await snapshot(page, '07-audit-log', results);

    const companiesExport = await context.request.get(`${baseUrl}/portal/export/companies.csv`);
    const companiesCsv = await companiesExport.text();
    results.metrics.companiesCsvHasHeader = /active_seats|organization|external_ref/i.test(companiesCsv);

    const usersExport = await context.request.get(`${baseUrl}/portal/export/users.csv`);
    const usersCsv = await usersExport.text();
    results.metrics.usersCsvHasHeader = /phone_number|organization_id|status/i.test(usersCsv);

    const usageExport = await context.request.get(`${baseUrl}/portal/export/usage.csv`);
    const usageCsv = await usageExport.text();
    results.metrics.usageCsvHasHeader = /billable_minutes|phone_number|call_count/i.test(usageCsv);

    results.checks.loginCompleted = results.pages.some((item) => item.url.includes('/portal/dashboard'));
    results.checks.dashboardVisible = results.pages.some((item) => item.label === '04-dashboard' && /Customer Companies|Billable Seats|Projected Monthly Bill/i.test(item.excerpt));
    results.checks.companyGroupingVisible = results.metrics.companyCardCount > 0;
    results.checks.billingVisible = results.pages.some((item) => item.label === '06-billing-center' && /Billing Center|Company Rollup|User Usage/i.test(item.excerpt));
    results.checks.auditVisible = results.pages.some((item) => item.label === '07-audit-log' && /Audit Log|Recent Events|Action/i.test(item.excerpt));
    results.checks.exportsVisible = Boolean(results.metrics.companiesCsvHasHeader && results.metrics.usersCsvHasHeader && results.metrics.usageCsvHasHeader);
    results.ok = Object.values(results.checks).every(Boolean);
  } finally {
    await browser.close();
  }

  const resultPath = `${outDir}/portal-clickthrough-result.json`;
  writeFileSync(resultPath, `${JSON.stringify(results, null, 2)}\n`);
  console.log(`RESULT ${resultPath}`);
  console.log(JSON.stringify({ ok: results.ok, checks: results.checks, metrics: results.metrics, outDir }, null, 2));
  if (!results.ok) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(`CLICKTHROUGH_FAILED ${error.message}`);
  process.exit(1);
});
