import { expect } from "@playwright/test";
import {
  DEMO_ACCOUNT_FAKEID,
  DEMO_ACCOUNT_NAME,
  DEMO_ARTICLE_KEYWORD,
  DEMO_ARTICLE_TITLE,
  gotoAccounts,
  login,
  shot,
  test
} from "../support/helpers";

// 主链路（weread_native 默认 provider）：触发抓取 → 微信读书最新文章接口
//（mock 的 /api/mp/cover + /web/mp/content 元数据页）→ 文章落库（link 指向
// 原始 mp.weixin 地址）→ 正文下载（mock HTTP 直连 /s/<slug>）→ 详情页渲染。
// 外部依赖全部由 e2e/fixtures 回放。
test("微信抓取主链路：触发 → 落库 → 正文下载 → 详情展示", async ({ page, shot }) => {
  await login(page);
  await gotoAccounts(page);
  await page.getByText(DEMO_ACCOUNT_NAME).first().click();
  await expect(page).toHaveURL(/\/accounts\/\d+/);

  await page.getByRole("button", { name: "立即抓取" }).first().click();
  await expect(page).toHaveURL(/\/crawl_tasks\/\d+/);
  await shot("40-任务已创建");

  // 后台任务（dev 为进程内 async 适配器）推进，任务页每 3s 轮询刷新状态
  await expect(page.locator('[data-task-status="completed"]')).toBeVisible({ timeout: 90_000 });
  await shot("41-任务完成");

  // 文章列表出现抓取结果
  await page.goto("/articles");
  const titleLink = page.getByRole("link", { name: DEMO_ARTICLE_TITLE }).first();
  await expect(titleLink).toBeVisible();
  await shot("42-文章列表");

  // 正文由 WechatContentDownloadJob 异步下载；标题链接 target=_blank 新开标签
  const [articlePage] = await Promise.all([
    page.waitForEvent("popup"),
    titleLink.click()
  ]);
  await expect(articlePage).toHaveURL(/\/articles\/\d+/);
  await expect(async () => {
    await articlePage.reload();
    await expect(articlePage.getByText(DEMO_ARTICLE_KEYWORD, { exact: true })).toBeVisible();
    await expect(articlePage.locator(".article-content img").first()).toBeVisible();
  }).toPass({ timeout: 90_000 });
  await shot("43-文章正文渲染", articlePage);

  // 配图确实加载成功（data-src → src 修复 + 本地 SVG 可访问）
  const img = articlePage.locator(".article-content img").first();
  await expect
    .poll(() => img.evaluate((el) => (el as HTMLImageElement).naturalWidth), { timeout: 15_000 })
    .toBeGreaterThan(0);
});

// 幂等回归：重复抓取不得产生重复文章（Article.url 唯一约束 + 去重逻辑）。
// weread_native 每次只暴露最新一篇，抓取前后 RSS 条数应保持不变。
test("重复抓取保持文章不重复", async ({ page, shot }) => {
  await login(page);
  await gotoAccounts(page);
  await page.getByText(DEMO_ACCOUNT_NAME).first().click();
  await expect(page).toHaveURL(/\/accounts\/\d+/);

  const rssCount = async () => {
    const resp = await page.request.get(`/rss/${DEMO_ACCOUNT_FAKEID}`);
    expect(resp.status()).toBe(200);
    return (await resp.text()).match(/<item[\s>]/g)?.length ?? 0;
  };

  await page.getByRole("button", { name: "立即抓取" }).first().click();
  await expect(page).toHaveURL(/\/crawl_tasks\/\d+/);
  await expect(page.locator('[data-task-status="completed"]')).toBeVisible({ timeout: 90_000 });
  const countBefore = await rssCount();
  expect(countBefore).toBeGreaterThan(0);
  await shot("44-第一次抓取完成");

  await gotoAccounts(page);
  await page.getByText(DEMO_ACCOUNT_NAME).first().click();
  await page.getByRole("button", { name: "立即抓取" }).first().click();
  await expect(page).toHaveURL(/\/crawl_tasks\/\d+/);
  await expect(page.locator('[data-task-status="completed"]')).toBeVisible({ timeout: 90_000 });
  expect(await rssCount()).toBe(countBefore);
  await shot("45-第二次抓取后条数不变");
});
