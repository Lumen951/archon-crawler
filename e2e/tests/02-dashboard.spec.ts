import { expect } from "@playwright/test";
import { login, shot, test } from "../support/helpers";

// 控制台概览：种子数据（1 个公众号）应当体现在统计卡片里。
test("控制台展示帐号/文章统计与最近动态", async ({ page, shot }) => {
  await login(page);
  await expect(page).not.toHaveURL(/session\/new/);
  await expect(page.getByText("内容源总数").first()).toBeVisible();
  await expect(page.getByText("内容总数").first()).toBeVisible();
  await expect(page.getByText("活跃任务").first()).toBeVisible();
  await expect(page.getByText("最近的抓取任务")).toBeVisible();
  await expect(page.getByText("RSS 订阅")).toBeVisible();
  await shot("10-控制台概览");
});
