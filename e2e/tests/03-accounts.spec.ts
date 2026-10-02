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
