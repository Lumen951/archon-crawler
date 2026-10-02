---
name: prod-sample
description: Pull a sample of REAL production data from the Kamal-deployed mp-crawler server into e2e/fixtures/samples/ so E2E tests run on realistic data. Use when the user asks to 采样生产数据 / 拉一份真实数据 / 导出生产数据做测试 / refresh e2e samples / 更新样本. Strictly READ-ONLY on the server (only SELECTs and writes to the storage volume) unless the user explicitly asks for modifications.
---

# 生产数据采样（Kamal，只读）

把生产库里的少量真实数据（帐号名、文章标题/摘要/正文排版）导出到服务器
storage 卷，取回本地放进 `e2e/fixtures/samples/`，让 E2E 回归跑在贴近真实
的数据形态上。样本同时会：作为种子数据灌进 E2E 数据库、并按 mock 层的
fixture 约定覆盖同名报文（见下"产出结构"）。

## 红线（先读）

- **服务器上只做只读操作**：导出脚本只 SELECT，写入仅限 `/rails/storage`
  卷里我们自己的导出文件。不改业务数据、不改配置、不重启容器、不动
  `.kamal/secrets`——除非用户明确要求。
- 导出脚本字段白名单：绝不导出 Option（cookies/tokens/API keys）、User、
  Session、ApiKey、OAuth、BrowserLogin 会话、日志等凭据或运维数据。改脚本
  时保持这个约束。
- 样本落在 `e2e/fixtures/samples/`（gitignore）——**真实数据绝不提交**。
- 导出前不需要通知用户确认（只读），但**取回的样本内容不要原样贴进对话或
  报告**，只描述数量和结构。

## 前置条件

- 服务器配置在 `config/deploy.yml`（service: mp_crawler，host:
  mp-crawler.miracleplus.com，storage 卷 `mp_crawler_storage:/rails/storage`），
  SSH key 用 `~/.ssh/livekit.pem`。
- 本地能跑 `bin/kamal ...`（kamal gem 在 Gemfile 里）。

## 步骤

### 1. 把导出脚本放进服务器 storage 卷

```bash
bin/kamal app exec -i "cat > /rails/storage/e2e_sample_export.rb" < script/prod_sample_export.rb
```

如果这个版本的 kamal 不支持 stdin 管道，用 ssh + docker cp 兜底：

```bash
scp -i ~/.ssh/livekit.pem script/prod_sample_export.rb ubuntu@mp-crawler.miracleplus.com:/tmp/
ssh -i ~/.ssh/livekit.pem ubuntu@mp-crawler.miracleplus.com \
  'docker cp /tmp/e2e_sample_export.rb $(docker ps --filter name=mp_crawler-web -q | head -1):/rails/storage/'
```

### 2. 在服务器上执行（只读 runner）

```bash
bin/kamal app exec --reuse "bin/rails runner /rails/storage/e2e_sample_export.rb"
```

想调样本量时把参数写进命令（用户要求"多采几个号"之类的场景）：

```bash
bin/kamal app exec --reuse "SAMPLE_MAX_ACCOUNTS=5 SAMPLE_MAX_ARTICLES=8 SAMPLE_MAX_CONTENT=6 bin/rails runner /rails/storage/e2e_sample_export.rb"
```

脚本结束会打印 `[prod_sample_export] 完成：帐号 N，文章 M，正文 K`。

### 3. 取回并展开到 samples/

```bash
bin/kamal app exec -i "tar -C /rails/storage -czf - e2e_sample" > tmp/e2e_sample.tgz
mkdir -p e2e/fixtures/samples
tar -xzf tmp/e2e_sample.tgz -C e2e/fixtures/samples --strip-components=1
```

（`-i` 无 tty，tar.gz 二进制流是安全的；如果输出损坏改用 ssh + docker cp
先在服务器上打包到 storage，再分文件 cat 取回。）

### 4. 验证并跑一轮回归

```bash
cat e2e/fixtures/samples/manifest.json   # 看数量与导出时间
bin/e2e                                  # 样本自动进种子 + mock 回放
```

- 样本帐号/文章会出现在 E2E 的帐号列表和文章列表里，截图里就是真实标题。
- `samples/weread_native/cover/<book_id>.json` 会覆盖对应公众号的
  「最新一篇」mock 响应，`samples/weread_native/content/<review_id>.html`
  覆盖对应正文页——由 mock 层自动优先读取 samples，无需改代码。
- 合成 fixture（E2E演示公众号）与样本共存，既有 10 个用例不受影响；
  如果某个用例因样本数据变化而失败，按 e2e-regression skill 的排查顺序处理。

### 5. 收尾（可选）

服务器 storage 卷里的导出脚本和样本目录不影响运行，如用户要求清理：

```bash
bin/kamal app exec --reuse "rm /rails/storage/e2e_sample_export.rb && rm -rf /rails/storage/e2e_sample"
```

## 产出结构（与 e2e/fixtures 同名约定）

```
e2e/fixtures/samples/
  manifest.json                            导出元信息（时间/数量/limits）
  accounts.json                            帐号样本 → e2e:seed 自动建帐号（含 weread book_id）
  wechat_articles.json                     文章元数据 → e2e:seed 自动建文章
  weread_native/cover/<book_id>.json       weread_native 最新文章接口按 book_id 覆盖
  weread_native/content/<review_id>.html   weread_native 正文页（cgiDataNew 元数据 + 正文）
  wechat_mp/articles/<slug>.html           mp.weixin 形态文章页（种子提取正文用）
```
