import { defineConfig, devices } from "@playwright/test";

// E2E 浏览器回归配置。服务器与数据库由 bin/e2e 负责（E2E_MOCKS=1 +
// 独立 E2E_DB_NAME），这里只管跑用例和产出报告。
// 报告（含失败视频/trace/关键步骤截图）：npx playwright show-report
const PORT = process.env.E2E_PORT ?? "3001";

export default defineConfig({
  testDir: "./tests",
  // 抓取/正文下载链路靠 Rails 后台任务（dev 环境 async 适配器）推进，留足轮询时间
  timeout: 120_000,
  expect: { timeout: 25_000 },
  // 共享一个 Rails 进程和一份 E2E 数据库，必须串行
  workers: 1,
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  reporter: [
    ["html", { open: "never" }],
    ["list"],
    // 生成 e2e/report.html：双击即可打开的静态结果入口页
    ["./support/summary-reporter"]
  ],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    locale: "zh-CN",
    viewport: { width: 1440, height: 900 },
    screenshot: "only-on-failure",
    video: "on",
    trace: "retain-on-failure",
    actionTimeout: 20_000
  },
  outputDir: "./test-results"
});
