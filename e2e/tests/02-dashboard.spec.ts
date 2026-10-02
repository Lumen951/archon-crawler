import { expect } from "@playwright/test";
import { login, shot, test } from "../support/helpers";

// 控制台概览：种子数据（1 个公众号）应当体现在统计卡片里。
test("控制台展示帐号/文章统计与最近动态", async ({ page, shot }) => {
  await login(page);
  await expect(page).not.toHaveURL(/session\/new/);
  await expect(page.getByText("帐号总数").first()).toBeVisible();
  await expect(page.getByText("启用的帐号").first()).toBeVisible();
  await expect(page.getByText("文章总数").first()).toBeVisible();
  await shot("10-控制台概览");
});
