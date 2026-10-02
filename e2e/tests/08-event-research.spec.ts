import { expect } from "@playwright/test";
import { gotoAccounts, login, shot, test } from "../support/helpers";

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

  // 从帐号列表点击活动账号，应被引导到研究控制台
  await gotoAccounts(page);
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
  await gotoAccounts(page);
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

test("下载数据 JSON：结果以 JSON 形态提供", async ({ page, shot }) => {
  await login(page);
  await gotoAccounts(page);
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
