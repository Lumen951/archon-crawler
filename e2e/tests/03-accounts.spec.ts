import { expect } from "@playwright/test";
import { DEMO_ACCOUNT_NAME, gotoAccounts, login, shot, test } from "../support/helpers";

test("帐号列表展示种子公众号，并可进入详情", async ({ page, shot }) => {
  await login(page);
  await gotoAccounts(page);
  await expect(page.getByText(DEMO_ACCOUNT_NAME).first()).toBeVisible();
  await shot("20-帐号列表");

  await page.getByText(DEMO_ACCOUNT_NAME).first().click();
  await expect(page).toHaveURL(/\/accounts\/\d+/);
  await expect(page.getByRole("button", { name: "立即抓取" })).toBeVisible();
  await shot("21-帐号详情");
});

test("官网导入表单创建 WebsiteAccount（纯本地，无外部依赖）", async ({ page, shot }) => {
  await login(page);
  await page.goto("/accounts/import/website");
  await page.getByRole("textbox").fill("E2E Mock Blog, https://blog.mock.dev");
  await page.getByRole("button", { name: "导入官网" }).click();

  await expect(page).toHaveURL(/\/accounts/);
  await expect(page.getByText("E2E Mock Blog").first()).toBeVisible();
  await shot("22-官网导入结果");
});

test("论文统一导入展示两种来源和失败结果，重复链接保持同一论文", async ({ page, shot }) => {
  await login(page);
  await page.goto("/papers/import");
  await page.getByLabel("论文链接").fill([
    "https://arxiv.org/abs/2401.00001",
    "https://openreview.net/forum?id=e2e-paper",
    "https://openreview.net/forum?id=denied"
  ].join("\n"));
  await page.getByRole("button", { name: "提交导入" }).click();
  await expect(page.locator('[data-task-status="failed"]')).toBeVisible();
  await expect(page.getByText("OpenReview 返回 HTTP 403", { exact: false })).toBeVisible();
  const paperLink = page.getByRole("link", { name: "E2E Continual Learning" });
  const firstPath = await paperLink.getAttribute("href");
  await expect(page.getByRole("link", { name: "E2E Robot Learning" })).toBeVisible();
  await shot("23-论文导入结果");
  await paperLink.click();
  await expect(page.getByRole("heading", { name: "E2E Continual Learning" })).toBeVisible();
  await expect(page.getByText("Example Author", { exact: true })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect.poll(async () => page.locator('[data-sidebar-target="panel"]').evaluate(
    (element) => element.getBoundingClientRect().right
  )).toBeLessThanOrEqual(0);
  await expect.poll(async () => page.evaluate(
    () => document.documentElement.scrollWidth <= window.innerWidth
  )).toBe(true);
  await shot("24-论文详情移动端");
  await page.goto("/papers/import");
  await page.getByLabel("论文链接").fill("https://arxiv.org/pdf/2401.00001v1.pdf");
  await page.getByRole("button", { name: "提交导入" }).click();
  await expect(page.locator('[data-task-status="completed"]')).toBeVisible();
  await expect(page.getByRole("link", { name: "E2E Continual Learning" })).toHaveAttribute("href", firstPath!);
  await shot("25-重复论文导入");
});
