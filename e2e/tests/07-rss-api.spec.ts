import { expect } from "@playwright/test";
import { DEMO_ARTICLE_TITLE, login, shot, test } from "../support/helpers";

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
