import { expect } from "@playwright/test";
import { DEMO_ACCOUNT_NAME, gotoAccounts, gotoEventAccounts, login, shot, test } from "../support/helpers";

// 活动研究（Event Research）端到端闭环：
// 导入活动配置 → 研究控制台 → 启动调研（Serper/网页/LLM/天眼查全部 mock）→
// 结果 JSON 落库并渲染 → 随时重启调研 → 下载数据 JSON。
const EVENT_NAME = "E2E创新创业大赛";

test("导入活动研究账号并展示配置摘要", async ({ page, shot }) => {
  await login(page);
  await page.goto("/accounts/import");
  await page.getByRole("heading", { name: "活动研究" }).click();
  await expect(page).toHaveURL(/\/accounts\/import\/event/);

  await page.getByPlaceholder("例如：科创中国创新创业投资大会").fill(EVENT_NAME);
  await page.getByPlaceholder("https://... 官网、获奖公示页等").fill("https://news.e2e-event.test/award-list");
  await page.getByPlaceholder("例如：\n获奖名单\n决赛\n路演").fill("获奖名单\n路演");
  await page.getByPlaceholder("例如：找出获奖项目的创始人联系方式，用于投资尽调").fill("找出获奖项目创始人背景");
  await page.getByRole("checkbox", { name: "每周自动研究并推送新增信息" }).check();
  await page.getByLabel("飞书目标类型").selectOption("chat_id");
  await page.getByLabel("飞书目标 ID（可选）").fill("oc_e2e_weekly");

  await page.getByRole("button", { name: "创建活动配置" }).click();

  // 创建后直接进入独立的研究控制台（不进文章账号 show 页）
  await expect(page).toHaveURL(/\/event_accounts\/\d+/);
  await expect(page.getByRole("heading", { name: EVENT_NAME })).toBeVisible();
  await expect(page.getByText("找出获奖项目创始人背景")).toBeVisible();
  await expect(page.getByText("路演", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "https://news.e2e-event.test/award-list" })).toBeVisible();
  await shot("80-活动配置摘要");
});

test("启动调研：后台跑完后展示结果数据与过程日志", async ({ page, shot }) => {
  await login(page);

  // 从活动调研 tab 点击活动账号，应被引导到研究控制台
  await gotoEventAccounts(page);
  await page.getByRole("link", { name: EVENT_NAME }).first().click();
  await expect(page).toHaveURL(/\/event_accounts\/\d+/);

  // 启动调研并等它完成（外部依赖全部由本地 mock 回放，全程不触网）
  await page.getByRole("button", { name: "开始调研" }).click();
  await expect(page).toHaveURL(/run_id=\d+/);
  await expect(page.locator('[data-task-status="completed"]')).toBeVisible({ timeout: 90_000 });

  // 结果数据：获奖名单 / 人物（含联系方式）/ 公司工商档案（天眼查交叉任职）
  await expect(page.getByText("获奖名单（1 条）")).toBeVisible();
  await expect(page.getByText("张三").first()).toBeVisible();

  await page.getByText("人物（去重后）").click();
  await expect(page.getByText("zhangsan@e2e-mock.dev").first()).toBeVisible();
  await expect(page.getByText("E2E大学").first()).toBeVisible();
  await expect(page.getByText(/工商任职：E2E示例科技有限公司/)).toBeVisible();

  await page.getByText("公司工商档案（1 家）").click();
  // 注册资本来自天眼查档案，只有公司表格会渲染它
  await expect(page.getByRole("cell", { name: "1000万人民币" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "张三" }).first()).toBeVisible();

  // 过程日志面板：能看到搜索与抓取的详细轨迹
  await expect(page.getByText(/Search: .*E2E创新创业大赛/).first()).toBeVisible();
  await expect(page.getByText(/Fetch \[\d+\/\d+\]/).first()).toBeVisible();

  // 调研记录里有一行已完成的运行
  await expect(page.getByText("调研记录")).toBeVisible();
  await expect(page.locator('[data-task-status] tr', { hasText: "completed" })).toHaveCount(1);
  await shot("81-调研结果");

  // 完整日志页可用
  await page.getByRole("link", { name: "查看全部日志" }).click();
  await expect(page).toHaveURL(/\/event_accounts\/\d+\/logs/);
  await expect(page.getByText("调研日志")).toBeVisible();
  await shot("82-调研日志页");
});

test("重新启动调研（忽略缓存）产生新一轮运行", async ({ page, shot }) => {
  await login(page);
  await gotoEventAccounts(page);
  await page.getByRole("link", { name: EVENT_NAME }).first().click();
  await expect(page).toHaveURL(/\/event_accounts\/\d+/);

  await page.getByRole("checkbox", { name: "忽略缓存重新计算" }).check();
  await page.getByRole("button", { name: "重新启动调研" }).click();
  await expect(page).toHaveURL(/run_id=\d+/);
  await expect(page.locator('[data-task-status="completed"]')).toBeVisible({ timeout: 90_000 });

  // 调研记录出现第二轮，且带「忽略缓存」备注
  await expect(page.getByRole("cell", { name: "忽略缓存" })).toBeVisible();
  await expect(page.locator('[data-task-status] tr', { hasText: "completed" })).toHaveCount(2);
  await shot("83-重启调研");
});

test("查看生成的周报及实际消息正文", async ({ page, shot }) => {
  await login(page);
  await gotoEventAccounts(page);
  await page.getByRole("link", { name: EVENT_NAME }).first().click();
  await expect(page).toHaveURL(/\/event_accounts\/\d+/);

  await page.getByRole("link", { name: "查看周报" }).click();
  await expect(page).toHaveURL(/\/event_accounts\/\d+\/weekly_reports/);
  await expect(page.getByRole("heading", { name: "周报 \/ 飞书通知" })).toBeVisible();
  await expect(page.getByRole("link", { name: "首发" })).toBeVisible();
  await expect(page.getByRole("link", { name: "周报" })).toBeVisible();
  await expect(page.getByRole("button", { name: "生成通知" })).toHaveCount(0);
  await expect(page.getByText("chat_id / oc_e2e_weekly").first()).toBeVisible();
  const notificationCount = await page.locator("tbody tr").count();
  await shot("85-周报列表");

  await page.getByRole("link", { name: "周报" }).first().click();
  await expect(page).toHaveURL(/\/weekly_reports\/\d+/);
  await expect(page.getByRole("heading", { name: "周报详情" })).toBeVisible();
  await expect(page.getByText("实际生成的消息")).toBeVisible();
  await expect(page.locator("pre")).toContainText("本周新增与补充");
  await shot("86-周报详情");

  await page.getByRole("link", { name: "← 返回周报列表" }).click();
  await expect(page).toHaveURL(/\/weekly_reports/);
  await page.getByRole("button", { name: "重新推送" }).first().click();
  await expect(page).toHaveURL(/\/weekly_reports/);
  await expect(page.getByText("已加入重新推送队列")).toBeVisible();
  await expect(page.locator("tbody tr")).toHaveCount(notificationCount);
});

test("下载数据 JSON：结果以 JSON 形态提供", async ({ page, shot }) => {
  await login(page);
  await gotoEventAccounts(page);
  await page.getByRole("link", { name: EVENT_NAME }).first().click();
  await expect(page).toHaveURL(/\/event_accounts\/\d+/);

  const href = await page.getByRole("link", { name: "下载数据 JSON" }).first().getAttribute("href");
  expect(href).toBeTruthy();

  const response = await page.request.get(href!);
  expect(response.status()).toBe(200);
  expect(response.headers()["content-type"]).toContain("application/json");

  const data = await response.json();
  expect(data.event.name).toBe(EVENT_NAME);
  expect(data.awards[0].people[0].name).toBe("张三");
  expect(data.metadata.research_config.purpose).toBe("找出获奖项目创始人背景");
  await shot("84-数据下载");
});

test("活动调研 tab：列表展示调研概况，文章帐号不混排", async ({ page, shot }) => {
  await login(page);

  // 默认 tab 只有文章帐号，活动账号不在其中
  await gotoAccounts(page);
  await expect(page.getByRole("link", { name: EVENT_NAME })).toHaveCount(0);

  await gotoEventAccounts(page);
  const row = page.locator("tbody tr", { hasText: EVENT_NAME });
  await expect(page.getByRole("link", { name: EVENT_NAME }).first()).toBeVisible();
  // 调研概况：此前用例已完成两轮调研
  await expect(row.getByText("2 次调研 · 完成 2")).toBeVisible();
  await expect(row.getByText(/最近：/)).toBeVisible();
  // 周定期调研徽标（种子活动开启了每周研究且帐号启用中）
  await expect(row.getByText("已开启", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: DEMO_ACCOUNT_NAME })).toHaveCount(0);
  await shot("87-活动调研列表");

  // 周调研筛选 pills：点「周调研已开启」仍能看到该活动
  await page.getByRole("link", { name: /周调研已开启/ }).click();
  await expect(page.getByRole("link", { name: EVENT_NAME }).first()).toBeVisible();
  await shot("88-周调研筛选");

  // 再点「全部活动」要真正清除筛选（显式传 all，不能被 QueryPersistence 恢复回旧筛选）
  await page.getByRole("link", { name: /全部活动/ }).click();
  await expect(page).toHaveURL(/with_weekly_research%5D=all/);
  await expect(page.getByRole("link", { name: EVENT_NAME }).first()).toBeVisible();
});

test("批量开启/关闭周调研", async ({ page, shot }) => {
  await login(page);
  await gotoEventAccounts(page);

  const row = page.locator("tbody tr", { hasText: EVENT_NAME });
  await page.locator('input[data-bulk-selector-target="checkbox"]').first().check();
  const bar = page.locator('[data-bulk-selector-target="actionBar"]');
  await expect(bar).toBeVisible();

  await bar.getByRole("button", { name: "关闭周调研" }).click();
  // 操作后必须停留在活动 tab（页面 no-referrer，服务端按 scope 显式回退）
  await expect(page).toHaveURL(/scope=event/);
  await expect(page.getByText("已关闭 1 个活动的每周定期调研")).toBeVisible();
  await expect(row.getByText("未开启", { exact: true })).toBeVisible();

  await page.locator('input[data-bulk-selector-target="checkbox"]').first().check();
  await bar.getByRole("button", { name: "开启周调研" }).click();
  await expect(page).toHaveURL(/scope=event/);
  await expect(page.getByText("已开启 1 个活动的每周定期调研")).toBeVisible();
  await expect(row.getByText("已开启", { exact: true })).toBeVisible();
  await shot("89-批量周调研");
});

test("行内停用/启用后停留在活动 tab", async ({ page }) => {
  await login(page);
  await gotoEventAccounts(page);

  const row = page.locator("tbody tr", { hasText: EVENT_NAME });
  await row.getByRole("button", { name: "停用" }).click();
  await expect(page).toHaveURL(/scope=event/);
  await expect(row.getByRole("button", { name: "启用" })).toBeVisible();

  await row.getByRole("button", { name: "启用" }).click();
  await expect(page).toHaveURL(/scope=event/);
  await expect(row.getByRole("button", { name: "停用" })).toBeVisible();
});
