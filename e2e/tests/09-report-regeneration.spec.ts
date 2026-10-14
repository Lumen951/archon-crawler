import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { expect } from "@playwright/test";
import { login, test } from "../support/helpers";

test("保存报告重新生成且手机布局没有横向滚动", async ({ page, shot }) => {
  const root = resolve(__dirname, "../..");
  const output = execFileSync(resolve(root, "bin/rails"), [ "runner", "digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, sections: { 'summary' => { 'events' => 1, 'people' => 2 } }, payload_text: '浏览器验证报告'); puts digest.id" ], {
    cwd: root, env: { ...process.env, E2E_MOCKS: "1", E2E_DB_NAME: process.env.E2E_DB_NAME ?? "mp_crawler_e2e" }, encoding: "utf8"
  });
  const id = output.trim().split("\n").at(-1);
  await login(page);
  await page.goto(`/event_weekly_digests/${id}`);
  await expect(page).toHaveURL(/\/event_weekly_digests\/\d+$/);
  const url = page.url();
  await expect(page.getByRole("button", { name: "重新生成内容" })).toBeVisible();
  await expect(page.getByText("最近一次推送状态")).toBeVisible();
  await page.getByRole("button", { name: "重新生成内容" }).click();
  await expect(page).toHaveURL(url);
  await expect(page.getByText("研究报告内容已重新生成，未自动推送")).toBeVisible();
  await expect(page.getByRole("heading", { name: "当前报告纯文本预览" })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy();
  await shot("报告重新生成手机布局");
});
