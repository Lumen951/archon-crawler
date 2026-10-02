import { Page, expect, test as base } from "@playwright/test";

// 种子数据（lib/e2e/seeder.rb 与 e2e/fixtures/wechat_mp/* 的对应关系）
export const DEMO_ACCOUNT_NAME = "E2E演示公众号";
export const DEMO_ACCOUNT_FAKEID = "3876543210";
export const DEMO_ARTICLE_TITLE = "E2E 回归测试：主流程链路验证";
export const DEMO_ARTICLE_KEYWORD = "流式链路验证完成";

// 带步骤截图的 test fixture：await shot("名称") 截全页并挂进 HTML 报告，
// 作为人工复核的"人眼证据"。target="_blank" 打开的新标签可传第二个参数。
// 另外给每个测试的浏览器上下文加离线护栏：除了 E2E 服务器自身，任何外部
// 请求一律 abort——防止 fixture 数据里的真实外链（如 mmbiz.qpic.cn）触网。
export const test = base.extend<{ shot: (name: string, target?: Page) => Promise<void> }>({
  context: async ({ context }, use) => {
    await context.route(/^(?!http:\/\/127\.0\.0\.1:3001\/)/, (route) => route.abort());
    await use(context);
  },
  shot: async ({ page }, use, testInfo) => {
    await use(async (name: string, target?: Page) => {
      const path = testInfo.outputPath(`${slug(name)}.png`);
      await (target ?? page).screenshot({ path, fullPage: true });
      await testInfo.attach(name, { path, contentType: "image/png" });
    });
  }
});

function slug(name: string): string {
  return name.replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "").slice(0, 60);
}

// 登录：优先走现成会话，否则点「开发者快速登录」（development 专属，
// 自动创建 dev@example.com 管理员）。根路径即控制台（dashboard#index）。
export async function login(page: Page): Promise<void> {
  await page.goto("/dashboard");
  if (!page.url().includes("session/new")) {
    return; // 已登录
  }
  await page.getByRole("button", { name: /开发者快速登录/ }).click();
  await expect(page).not.toHaveURL(/session\/new/);
  await expect(page.getByRole("heading", { name: "控制台" })).toBeVisible();
}

// 帐号列表页：accounts#index 开启了 QueryPersistenceConcern（按用户在服务端
// 记住上次的筛选条件，跨浏览器会话生效），reset=1 先清掉记忆，避免用例互相污染。
export async function gotoAccounts(page: Page): Promise<void> {
  await page.goto("/accounts?reset=1");
  await expect(page.getByRole("heading", { name: "帐号管理" })).toBeVisible();
}
