import { expect } from "@playwright/test";
import { DEMO_ARTICLE_TITLE, login, shot, test } from "../support/helpers";

test("日报可阅读且共享密钥仅添加者可修改", async ({ page, shot }) => {
  test.skip(process.env.DAILY_REPORT_E2E !== "1", "需要 DAILY_REPORT_E2E 专用种子");
  await login(page);
  await page.goto("/daily_reports");
  await page.getByRole("link", { name: /每日简报/ }).filter({ hasText: "2026年11月04日" }).click();
  await expect(page.getByRole("heading", { name: "离线日报验收" })).toBeVisible();
  await shot("日报正文");
  await page.goto("/profile/edit#llm-settings");
  const settings = page.locator("#llm-settings");
  await expect(settings).toContainText("未添加");
  await settings.locator("input[name=openai_api_key]").fill("e2e-first-key");
  await settings.getByRole("button", { name: "添加密钥", exact: true }).click();
  await expect(settings).toContainText("已添加");
  await settings.locator("input[name=openai_api_key]").fill("e2e-updated-key");
  await settings.getByRole("button", { name: "修改密钥", exact: true }).click();
  await expect(settings).toContainText("已修改");
  await expect(settings).not.toContainText("e2e-updated-key");
  await shot("添加者可修改密钥");
  await page.context().clearCookies();
  await page.goto("/session/new");
  await page.locator('input[name="email_address"]').fill("daily-reader@archon.tech");
  await page.locator('input[name="password"]').fill("e2ePassword123");
  await page.getByRole("button", { name: "进入工作台", exact: true }).click();
  await expect(page).not.toHaveURL(/session\/new/);
  await page.goto("/profile/edit#llm-settings");
  await expect(settings).toContainText("已修改");
  await expect(settings.locator("input[name=openai_api_key]")).toHaveCount(0);
  await expect(settings).toContainText("密钥已由其他用户添加");
  await shot("其他用户只读密钥状态");
});

// RSS 是公开端点（allow_unauthenticated_access），此时 05 已产出文章。
test("RSS 输出抓取到的文章", async ({ request }) => {
  const resp = await request.get("/rss");
  expect(resp.status()).toBe(200);
  expect(resp.headers()["content-type"]).toContain("xml");
  const xml = await resp.text();
  expect(xml).toContain(DEMO_ARTICLE_TITLE);
});

// API Key 生成 → Bearer 访问 /api/v1/articles。
test("API Key 创建后可经 Bearer 访问文章 API", async ({ page, request, shot }) => {
  await login(page);
  await page.goto("/profile/edit");

  await page.getByPlaceholder("例如：我的应用").fill("E2E 回归");
  await page.getByRole("button", { name: "生成 API Key" }).click();

  const tokenBlock = page.getByText("✅ API Key 已生成，请立即复制保存：");
  await expect(tokenBlock).toBeVisible();
  const token = (await page.locator("code.break-all").first().textContent())?.trim();
  expect(token, "页面上应显示完整 token").toBeTruthy();
  await shot("60-API Key 已生成");

  // 全局关键词搜索模式（默认 group 模式需要 group_ref_keys）
  const resp = await request.get("/api/v1/articles?keyword=" + encodeURIComponent("链路"), {
    headers: { Authorization: `Bearer ${token}` }
  });
  expect(resp.status()).toBe(200);
  const body = await resp.json();
  expect(JSON.stringify(body)).toContain(DEMO_ARTICLE_TITLE);

  // 无凭据访问应被拒绝
  const anon = await request.get("/api/v1/articles?keyword=test");
  expect(anon.status()).toBe(401);
});
