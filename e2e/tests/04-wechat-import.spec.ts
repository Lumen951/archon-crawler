import { expect } from "@playwright/test";
import { test, login, shot, gotoAccounts } from "../support/helpers";

// 微信文章链接导入（导入页默认 tab）：提交后台任务 → WechatUrlImportJob
// 解析文章页（mock 的 /s/MOCKARTICLE4，biz 解码为新 fakeid）→ 帐号落库。
test("微信文章链接导入：后台任务解析文章页并创建帐号", async ({ page, shot }) => {
  await login(page);
  await page.goto("/accounts/import/wechat");

  await page.locator("#url-tab textarea").first().fill("https://mp.weixin.qq.com/s/MOCKARTICLE4");
  await page.getByRole("button", { name: "提交后台导入" }).click();

  await expect(page).toHaveURL(/wechat_url_import_tasks\/\d+/);
  await expect(page.locator('[data-task-status="completed"]')).toBeVisible({ timeout: 60_000 });
  await expect(page.getByText("新导入").first()).toBeVisible();
  await shot("30-链接导入任务完成");

  await gotoAccounts(page);
  await expect(page.getByText("E2E第二公众号").first()).toBeVisible();
  await shot("31-新帐号出现在列表");
});
