import { expect } from "@playwright/test";
import { shot, test } from "../support/helpers";

// 登录/登出主流程。dev_login 仅 development 可用，自动创建管理员会话。
test("登录页 → 开发者快速登录 → 工作台 → 退出登录", async ({ page, shot }) => {
  await page.goto("/");
  await expect(page).toHaveURL(/session\/new/);
  await expect(page.getByRole("button", { name: /以 Archon Developer 身份进入/ })).toBeVisible();
  await shot("01-登录页");

  await page.getByRole("button", { name: /以 Archon Developer 身份进入/ }).click();
  await expect(page).not.toHaveURL(/session\/new/);
  await expect(page.getByRole("heading", { name: "工作台" })).toBeVisible();

  // 头部用户菜单 → 退出登录
  await page.locator('div[data-controller="dropdown"] > button').first().click();
  await page.getByText("退出登录").click();
  await expect(page).toHaveURL(/session\/new/);
  await shot("02-已退出登录");
});
