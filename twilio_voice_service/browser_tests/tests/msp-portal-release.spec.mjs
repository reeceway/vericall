import crypto from "node:crypto";
import { expect, test } from "@playwright/test";

const ADMIN_KEY = process.env.VICALL_ADMIN_API_KEY || "test-admin-key";
const TEST_OTP = process.env.VICALL_BROWSER_TEST_OTP || "111111";
const WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || "whsec_browser_local";
const PORTAL_PASSWORD = "VicallBrowser123!";
const APP_PUBLIC_KEY = "browser-test-app-public-key";

function expectMatch(pattern, value, label) {
  const match = value.match(pattern);
  expect(match, `Expected ${label} in response`).toBeTruthy();
  return match[1];
}

async function responseJson(response) {
  expect(response.ok(), await response.text()).toBeTruthy();
  return response.json();
}

function signedStripeEvent(event) {
  const payload = JSON.stringify(event);
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = crypto
    .createHmac("sha256", WEBHOOK_SECRET)
    .update(`${timestamp}.${payload}`)
    .digest("hex");
  return {
    payload,
    header: `t=${timestamp},v1=${signature}`
  };
}

test("portal, billing, audit, and app onboarding work end to end", async ({ page, request, baseURL, browserName }) => {
  const runId = `${Date.now()}`.slice(-6);
  const phoneSuffixOne = runId.slice(-4);
  const phoneSuffixTwo = `${(Number(phoneSuffixOne) + 1) % 10000}`.padStart(4, "0");
  const ownerEmail = `owner+${browserName}-${runId}@example.com`;
  const ownerPhone = `+1555000${phoneSuffixOne}`;
  const billingEmail = `billing+${browserName}-${runId}@example.com`;
  const companyOne = `Alpha Dental ${browserName} ${runId}`;
  const companyTwo = `Bravo Legal ${browserName} ${runId}`;
  const employeeOnePhone = `+1666000${phoneSuffixOne}`;
  const employeeTwoPhone = `+1777000${phoneSuffixTwo}`;
  const employeeOneIdentity = `user_${employeeOnePhone.slice(-4)}_prod1`;

  let mspId = "";
  let companyOneId = "";
  let companyOneCode = "";
  let companyTwoId = "";
  let companyTwoCode = "";
  let stripeCustomerId = "";
  let invoiceId = "";
  let seatInvoiceId = "";

  await test.step("provision the MSP and first company", async () => {
    const provisionResponse = await request.post(`/admin/provision-msp?key=${encodeURIComponent(ADMIN_KEY)}`, {
      form: {
        msp_name: `Codex Browser MSP ${browserName} ${runId}`,
        billing_email: billingEmail,
        owner_full_name: "Codex Browser Owner",
        owner_email: ownerEmail,
        owner_phone_number: ownerPhone,
        owner_password: PORTAL_PASSWORD,
        company_name: companyOne,
        external_ref: `CRM-${runId}`,
        seat_price_cents: "2000"
      }
    });
    const html = await provisionResponse.text();
    expect(provisionResponse.ok(), html).toBeTruthy();
    expect(html).not.toContain("Portal Key:");
    mspId = expectMatch(/MSP ID:<\/strong> <code>([^<]+)<\/code>/, html, "MSP ID");
    companyOneId = expectMatch(/Organization ID:<\/strong> <code>([^<]+)<\/code>/, html, "company one organization ID");
    companyOneCode = expectMatch(/Access Code:<\/strong> <code>([^<]+)<\/code>/, html, "company one access code");
    stripeCustomerId = expectMatch(/Stripe Customer:<\/strong> ([^<]+)/, html, "Stripe customer").replaceAll(/<\/?code>/g, "").trim();
    expect(stripeCustomerId).toMatch(/^cus_test_/);
  });

  await test.step("log in through the rendered portal", async () => {
    await page.goto(`${baseURL}/portal/login`);
    await expect(page.getByRole("heading", { name: "Vicall MSP Portal" })).toBeVisible();
    await expect(page.locator("body")).not.toContainText("Sign In with Portal Key");

    await page.locator('input[name="email"]').fill(ownerEmail);
    await page.locator('input[name="password"]').fill(PORTAL_PASSWORD);
    await Promise.all([
      page.waitForURL("**/portal/login/phone**"),
      page.getByRole("button", { name: "Continue" }).click()
    ]);

    await page.locator('input[name="phone_number"]').fill(ownerPhone);
    await Promise.all([
      page.waitForURL("**/portal/login/code**"),
      page.getByRole("button", { name: "Text Me a Code" }).click()
    ]);

    await page.locator('input[name="otp"]').fill(TEST_OTP);
    await Promise.all([
      page.waitForURL("**/portal/dashboard**"),
      page.getByRole("button", { name: "Sign In" }).click()
    ]);

    await expect(page.locator("body")).toContainText("Open Billing Center");
    await expect(page.locator("body")).toContainText("View Audit Log");
    await expect(page.locator("body")).toContainText(companyOne);
  });

  await test.step("create a second company in the browser", async () => {
    await page.locator("#partner-tools > summary").click();
    await page.locator('form[action="/portal/companies/create"] input[name="company_name"]').fill(companyTwo);
    await page.locator('form[action="/portal/companies/create"] input[name="external_ref"]').fill(`ERP-${runId}`);
    await Promise.all([
      page.waitForURL("**/portal/companies/create"),
      page.getByRole("button", { name: "Create Company" }).click()
    ]);

    await expect(page.getByRole("heading", { name: "Company Created" })).toBeVisible();
    const companyHtml = await page.content();
    companyTwoId = expectMatch(/Organization ID:<\/strong> <code>([^<]+)<\/code>/, companyHtml, "company two organization ID");
    companyTwoCode = expectMatch(/Access Code:<\/strong> <code>([^<]+)<\/code>/, companyHtml, "company two access code");

    await Promise.all([
      page.waitForURL("**/portal/dashboard**"),
      page.getByRole("link", { name: "Back to MSP Portal" }).click()
    ]);
    await expect(page.locator("body")).toContainText(companyTwo);
  });

  await test.step("complete app onboarding through org-backed access and OTP", async () => {
    const validateOne = await responseJson(await request.post("/access/validate", {
      data: { code: companyOneCode, phone_number: employeeOnePhone }
    }));
    expect(validateOne.organization_id).toBe(companyOneId);
    expect(validateOne.grant_token).toMatch(/^vicg_/);

    const requestOtpOne = await responseJson(await request.post("/access/request-otp", {
      data: {
        access_grant_token: validateOne.grant_token,
        phone_number: employeeOnePhone
      }
    }));
    expect(requestOtpOne.test_otp).toBe(TEST_OTP);

    const verifyOne = await responseJson(await request.post("/access/verify-otp", {
      data: {
        access_grant_token: validateOne.grant_token,
        phone_number: employeeOnePhone,
        otp: TEST_OTP,
        public_key: APP_PUBLIC_KEY
      }
    }));
    expect(verifyOne.organization_id).toBe(companyOneId);
    expect(verifyOne.user_id).toBe(`user_${employeeOnePhone.slice(-4)}`);
    expect(verifyOne.billing.status).toBe("skipped_billing_exempt");

    const validateTwo = await responseJson(await request.post("/access/validate", {
      data: { code: companyTwoCode, phone_number: employeeTwoPhone }
    }));
    expect(validateTwo.organization_id).toBe(companyTwoId);

    await responseJson(await request.post("/access/request-otp", {
      data: {
        access_grant_token: validateTwo.grant_token,
        phone_number: employeeTwoPhone
      }
    }));

    const verifyTwo = await responseJson(await request.post("/access/verify-otp", {
      data: {
        access_grant_token: validateTwo.grant_token,
        phone_number: employeeTwoPhone,
        otp: TEST_OTP,
        public_key: APP_PUBLIC_KEY
      }
    }));
    expect(verifyTwo.organization_id).toBe(companyTwoId);
    expect(verifyTwo.billing.status).toBe("invoiced");
    seatInvoiceId = verifyTwo.billing.invoice_id;
    expect(seatInvoiceId).toMatch(/^in_seat_test_/);
  });

  await test.step("refresh the portal and confirm seat rollup", async () => {
    await page.goto(`${baseURL}/portal/dashboard`);
    await expect(page.locator(".summary-card", { hasText: "Customer Companies" }).locator(".metric")).toHaveText("1");
    await expect(page.locator(".summary-card", { hasText: "Billable Seats" }).locator(".metric")).toHaveText("1");
    await expect(page.locator(".summary-card", { hasText: "Billable Seats" })).toContainText("2 active seats");
    await expect(page.locator(".summary-card", { hasText: "Payment" })).toContainText("Ready");
    await expect(page.locator("body")).toContainText("Top usage this month");
    await expect(page.locator("body")).toContainText(companyOne);
    await expect(page.locator("body")).toContainText(companyTwo);
  });

  await test.step("run billing, reconcile webhook status, and verify the billing center", async () => {
    const billingRun = await responseJson(await request.post(`/admin/msps/${mspId}/billing/run`, {
      headers: { "X-Admin-Key": ADMIN_KEY }
    }));
    expect(billingRun.status).toBe("skipped_zero_amount");
    invoiceId = seatInvoiceId;

    const event = signedStripeEvent({
      id: `evt_${runId}`,
      type: "invoice.paid",
      data: {
        object: {
          id: invoiceId,
          hosted_invoice_url: `${baseURL}/__test/stripe/invoices/${invoiceId}`,
          metadata: { msp_id: mspId }
        }
      }
    });
    const webhookResponse = await request.post("/stripe/webhook", {
      data: event.payload,
      headers: {
        "content-type": "application/json",
        "stripe-signature": event.header
      }
    });
    expect(webhookResponse.ok(), await webhookResponse.text()).toBeTruthy();

    await page.goto(`${baseURL}/portal/billing`);
    await expect(page.getByRole("heading", { name: /Billing Center$/ })).toBeVisible();
    await expect(page.locator("body")).toContainText("Invoice Timeline");
    await expect(page.locator("body")).toContainText("Company Rollup");
    await expect(page.locator("body")).toContainText("User Usage");
    await expect(page.locator("body")).toContainText(invoiceId);
    await expect(page.locator("body")).toContainText(companyOne);
    await expect(page.locator("body")).toContainText(companyTwo);

    const invoiceLink = page.locator(`a[href*="/__test/stripe/invoices/${invoiceId}"]`).first();
    const [invoicePage] = await Promise.all([
      page.context().waitForEvent("page"),
      invoiceLink.click()
    ]);
    await invoicePage.waitForLoadState("domcontentloaded");
    await expect(invoicePage.getByRole("heading", { name: "Stripe Test Invoice" })).toBeVisible();
    await expect(invoicePage.locator("body")).toContainText(invoiceId);
    await invoicePage.close();
  });

  await test.step("open the fake Stripe billing portal from the real portal UI", async () => {
    await Promise.all([
      page.waitForURL("**/__test/stripe/billing-portal**"),
      page.getByRole("button", { name: "Open Stripe Billing Portal" }).click()
    ]);
    await expect(page.getByRole("heading", { name: "Stripe Test Billing Portal" })).toBeVisible();
    await expect(page.locator("body")).toContainText(stripeCustomerId);
    await Promise.all([
      page.waitForURL("**/portal/dashboard"),
      page.getByRole("link", { name: "Return to Vicall MSP Portal" }).click()
    ]);
  });

  await test.step("finish the app account-deletion handoff in the browser", async () => {
    const prepareDelete = await responseJson(await request.post("/account/delete/prepare", {
      headers: { Authorization: "Bearer demo-delete-token" },
      data: {
        phone_number: employeeOnePhone,
        user_id: `user_${employeeOnePhone.slice(-4)}`,
        identity: employeeOneIdentity
      }
    }));
    expect(prepareDelete.mode).toBe("web");

    await page.goto(prepareDelete.manage_url);
    await expect(page.getByRole("heading", { name: "Delete Vicall account" })).toBeVisible();
    await Promise.all([
      page.waitForLoadState("domcontentloaded"),
      page.getByRole("button", { name: "Delete Account" }).click()
    ]);
    await expect(page.getByRole("heading", { name: "Vicall Account Deleted" })).toBeVisible();
    await expect(page.locator("body")).toContainText("Deactivated memberships:");
  });

  await test.step("confirm seat tracking and audit events after deletion", async () => {
    await page.goto(`${baseURL}/portal/dashboard`);
    await expect(page.locator(".summary-card", { hasText: "Customer Companies" }).locator(".metric")).toHaveText("1");
    await expect(page.locator(".summary-card", { hasText: "Billable Seats" }).locator(".metric")).toHaveText("1");
    await expect(page.locator(".summary-card", { hasText: "Billable Seats" })).toContainText("1 active seat");

    await page.goto(`${baseURL}/portal/audit`);
    await expect(page.getByRole("heading", { name: /Audit Log$/ })).toBeVisible();
    await page.locator('select[name="action"]').selectOption("system.billing.invoice_status_updated");
    await Promise.all([
      page.waitForURL("**/portal/audit**"),
      page.getByRole("button", { name: "Filter Audit Log" }).click()
    ]);
    await expect(page.locator("body")).toContainText("system.billing.invoice_status_updated");
    await expect(page.locator("body")).toContainText("paid");
    await expect(page.locator("body")).toContainText(invoiceId);
  });
});
