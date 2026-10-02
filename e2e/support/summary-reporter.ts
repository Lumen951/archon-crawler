import type { FullResult, Reporter, TestCase, TestResult } from "@playwright/test";
import { writeFileSync } from "fs";
import { relative, resolve } from "path";

// 结果入口页生成器：跑完 bin/e2e 后产出 e2e/report.html —— 双击即可打开的
// 汇总页（每个用例的状态/时长/关键步骤截图/失败现场/视频），不用先起
// `npx playwright show-report`。资源用相对路径引用（浏览器对 file:// 页面
// 允许加载同目录下的图片/视频）；深度排查仍用交互式报告。
//
// 报告在 playwright.config.ts 的 reporter 列表里注册，产物 gitignore。

interface AttachmentSummary {
  name: string;
  contentType: string;
  path: string;
}

interface TestSummary {
  title: string;
  file: string;
  status: string;
  durationMs: number;
  error: string | null;
  attachments: AttachmentSummary[];
}

const STATUS_LABELS: Record<string, { label: string; badge: string }> = {
  passed: { label: "通过", badge: "#16a34a" },
  failed: { label: "失败", badge: "#dc2626" },
  timedOut: { label: "超时", badge: "#dc2626" },
  skipped: { label: "跳过", badge: "#9ca3af" },
  interrupted: { label: "中断", badge: "#f59e0b" }
};

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function relPath(absolute: string): string {
  return relative(resolve(__dirname, ".."), absolute);
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function attachmentHtml(attachment: AttachmentSummary): string {
  const href = relPath(attachment.path);

  if (attachment.contentType === "image/png" || attachment.contentType === "image/jpeg") {
    return `
      <figure>
        <img src="${escapeHtml(href)}" alt="${escapeHtml(attachment.name)}" loading="lazy">
        <figcaption>${escapeHtml(attachment.name)}</figcaption>
      </figure>`;
  }

  if (attachment.contentType === "video/webm") {
    return `
      <figure>
        <video controls preload="none" src="${escapeHtml(href)}"></video>
        <figcaption>录屏（原始文件：${escapeHtml(href)}）</figcaption>
      </figure>`;
  }

  const label = attachment.path.endsWith(".zip") ? "trace.zip（npx playwright show-trace <路径>）" : escapeHtml(attachment.name);
  return `<p class="file-link">📎 <a href="${escapeHtml(href)}">${label}</a></p>`;
}

function testCard(test: TestSummary): string {
  const badge = STATUS_LABELS[test.status] ?? { label: test.status, badge: "#9ca3af" };
  const screenshots = test.attachments.filter((a) => a.contentType.startsWith("image/"));
  const others = test.attachments.filter((a) => !a.contentType.startsWith("image/"));

  const errorBlock = test.error
    ? `<pre class="error">${escapeHtml(test.error.slice(0, 3000))}</pre>`
    : "";

  const screenshotBlock = screenshots.length
    ? `<details ${test.status !== "passed" ? "open" : ""}>
         <summary>步骤截图（${screenshots.length}）</summary>
         ${screenshots.map(attachmentHtml).join("\n")}
       </details>`
    : "";

  const otherBlock = others.length
    ? `<details><summary>录屏与产物（${others.length}）</summary>${others.map(attachmentHtml).join("\n")}</details>`
    : "";

  return `
  <section class="card ${test.status === "passed" ? "ok" : "bad"}">
    <header>
      <span class="badge" style="background:${badge.badge}">${badge.label}</span>
      <h2>${escapeHtml(test.title)}</h2>
      <span class="meta">${escapeHtml(test.file)} · ${formatDuration(test.durationMs)}</span>
    </header>
    ${errorBlock}
    ${screenshotBlock}
    ${otherBlock}
  </section>`;
}

function buildHtml(tests: TestSummary[], overall: FullResult): string {
  const counts = tests.reduce<Record<string, number>>((acc, test) => {
    acc[test.status] = (acc[test.status] ?? 0) + 1;
    return acc;
  }, {});
  const totalMs = tests.reduce((sum, test) => sum + test.durationMs, 0);
  const failed = (counts.failed ?? 0) + (counts.timedOut ?? 0) + (counts.interrupted ?? 0);

  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>E2E 回归结果 · ${overall.status === "passed" ? "全部通过" : "存在失败"}</title>
<style>
  body { font-family: system-ui, "PingFang SC", "Microsoft YaHei", sans-serif; margin: 0; background: #f8fafc; color: #0f172a; }
  header.top { padding: 24px 32px; background: #fff; border-bottom: 1px solid #e2e8f0; }
  header.top h1 { margin: 0 0 6px; font-size: 22px; }
  header.top .overall { font-size: 14px; color: #475569; }
  .stats { display: flex; gap: 18px; margin-top: 12px; font-size: 14px; }
  .stats b { font-size: 18px; }
  main { max-width: 1080px; margin: 0 auto; padding: 24px 16px 64px; }
  .card { background: #fff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 16px 20px; margin: 16px 0; }
  .card.bad { border-color: #fecaca; }
  .card header { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .card h2 { font-size: 16px; margin: 0; }
  .card .meta { color: #64748b; font-size: 12px; }
  .badge { color: #fff; border-radius: 999px; padding: 2px 10px; font-size: 12px; }
  .badge[style*="#16a34a"] { color: #fff; }
  details { margin-top: 10px; }
  summary { cursor: pointer; font-size: 13px; color: #475569; }
  figure { margin: 10px 0; }
  figure img, figure video { max-width: 100%; border: 1px solid #e2e8f0; border-radius: 8px; }
  figcaption { font-size: 12px; color: #64748b; margin-top: 4px; }
  .file-link { font-size: 13px; margin: 8px 0; }
  pre.error { background: #fef2f2; border: 1px solid #fecaca; border-radius: 8px; padding: 12px; font-size: 12px; white-space: pre-wrap; word-break: break-word; overflow-x: auto; }
  footer { color: #64748b; font-size: 13px; padding: 0 32px 40px; }
  footer code { background: #e2e8f0; border-radius: 4px; padding: 1px 5px; }
</style>
</head>
<body>
<header class="top">
  <h1>E2E 回归结果</h1>
  <p class="overall">
    整体：<b style="color:${failed ? "#dc2626" : "#16a34a"}">${overall.status === "passed" ? "全部通过" : "存在失败"}</b>
    · 生成于 ${new Date().toLocaleString("zh-CN")}
  </p>
  <div class="stats">
    <span>用例 <b>${tests.length}</b></span>
    <span style="color:#16a34a">通过 <b>${counts.passed ?? 0}</b></span>
    <span style="color:#dc2626">失败 <b>${failed}</b></span>
    <span>跳过 <b>${counts.skipped ?? 0}</b></span>
    <span>总时长 <b>${formatDuration(totalMs)}</b></span>
  </div>
</header>
<main>
  ${tests.map(testCard).join("\n")}
</main>
<footer>
  <p>深度排查：在 <code>e2e/</code> 目录执行 <code>npx playwright show-report</code> 打开交互式报告（含时间线与网络）。</p>
  <p>本页为静态入口，双击即可打开；若浏览器不显示截图/录屏，可用静态服务：<code>python3 -m http.server -d e2e 8000</code> 后访问 <code>http://localhost:8000/report.html</code>。</p>
</footer>
</body>
</html>
`;
}

export default class SummaryReporter implements Reporter {
  private tests: TestSummary[] = [];

  onTestEnd(test: TestCase, result: TestResult): void {
    this.tests.push({
      title: test.title,
      file: relative(resolve(__dirname, ".."), test.location.file),
      status: result.status,
      durationMs: result.duration,
      error: result.error?.message ?? null,
      attachments: result.attachments.map((a) => ({
        name: a.name,
        contentType: a.contentType,
        path: a.path ?? ""
      })).filter((a) => a.path)
    });
  }

  onEnd(result: FullResult): void {
    const target = resolve(__dirname, "..", "report.html");
    writeFileSync(target, buildHtml(this.tests, result));
    console.log(`\n==> 结果入口页：${target}（双击打开）`);
  }
}
