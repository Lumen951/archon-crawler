import { expect } from "@playwright/test";
import { test, login, shot } from "../support/helpers";

// 微信读书（直连 weread.qq.com）扫码登录——唯一保留的微信抓取 provider。
// mock 状态机：每次重置后第 1-2 次轮询 waiting → 第 3 次起 success（随后
// weblogin + session/init 换取会话 Cookie）。设置页每 2.5s 轮询，全程无外网。
// 种子注入了有效会话，因此先在面板里退出登录，才能走到扫码入口。
test("微信读书（直连）扫码登录全流程", async ({ page, shot }) => {
  await login(page);
  // 设置页为面板切换式布局，#wechat 直达微信读书面板
  await page.goto("/admin/settings#wechat");

  const panel = page.locator("#weread_native_panel");
  await expect(panel).toBeVisible();
  // 种子已注入会话 → 面板初始为已登录
  await expect(panel.getByText("会话状态：✓ 已登录")).toBeVisible();
  await shot("50-设置页会话状态");

  // 退出登录（原生 confirm 对话框），让「获取登录二维码」入口出现
  page.on("dialog", (dialog) => dialog.accept());
  await panel.getByRole("button", { name: "退出登录" }).click();
  await expect(panel.getByRole("button", { name: "获取登录二维码" })).toBeVisible();

  // 发起扫码：confirm 链接在本地渲染成二维码图片（data URI 内联展示）
  await panel.getByRole("button", { name: "获取登录二维码" }).click();
  const qr = panel.locator('[data-qr-login-target="image"]');
  await expect(qr).toBeVisible();
  await expect(qr).toHaveAttribute("src", /^data:image\/png;base64,/);
  await shot("51-二维码已展示");

  // 状态机推进：等待扫码 → 登录成功（含 mock 账号昵称）
  await expect(page.getByText(/登录成功：/)).toBeVisible({ timeout: 30_000 });
  await shot("52-扫码登录成功");

  // 重新加载后面板回显最新会话状态
  await page.reload();
  await expect(page.locator("#weread_native_panel").getByText("会话状态：✓ 已登录")).toBeVisible();
});

// 小红书采集通道切换（付费 API / 浏览器直连）。设置页小红书卡片里的单选表单，
// 提交后 flash + 回显选中态。结束时切回默认 API，避免影响其他用例。
test("小红书采集通道切换", async ({ page, shot }) => {
  await login(page);
  // 设置页为面板切换式布局，#rednote 直达小红书面板
  await page.goto("/admin/settings#rednote");

  const card = page.locator("#rednote");
  await expect(card.getByRole("heading", { name: "采集通道" })).toBeVisible();
  await expect(card.locator('input[name="rednote_crawl_provider"][value="api"]')).toBeChecked();

  await card.locator('input[name="rednote_crawl_provider"][value="browser"]').check();
  await card.getByRole("button", { name: "保存采集通道" }).click();
  await expect(page.getByText("已切换为浏览器直连")).toBeVisible();
  await expect(card.locator('input[name="rednote_crawl_provider"][value="browser"]')).toBeChecked();
  await shot("53-采集通道已切换为浏览器直连");

  await card.locator('input[name="rednote_crawl_provider"][value="api"]').check();
  await card.getByRole("button", { name: "保存采集通道" }).click();
  await expect(page.getByText("已切换为付费 API")).toBeVisible();
  await expect(card.locator('input[name="rednote_crawl_provider"][value="api"]')).toBeChecked();
});
