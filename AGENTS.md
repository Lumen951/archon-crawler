# AGENTS.md

Guidance for Codex and other AI coding agents working in this repository.

## Repository Context

MP-Crawler is a Ruby on Rails 8.1 application for collecting articles from
WeChat official accounts, Rednote, Twitter/X, and websites, then exposing the
data through the web UI, RSS feeds, REST APIs, and an MCP server. It uses
PostgreSQL, Solid Queue, Solid Cache, Solid Cable, Turbo/Stimulus, and Kamal.

`Account` is an STI base model. The supported account types are
`WechatAccount`, `RednoteAccount`, `TwitterAccount`, and `WebsiteAccount`.
Platform crawlers live primarily in `lib/`; `CrawlOrchestrator` dispatches an
account to its type's crawler through `Account.crawler_class`.

Crawler runs make network calls and write durable data. Treat crawler logic,
job scheduling, persisted crawl state, account credentials, and OAuth/MCP
authorization as high-risk surfaces.

## Default Rules

- Read the existing controller, model, job, service, and crawler path before
  changing it. Prefer the repository's established patterns.
- Keep changes narrowly scoped to the requested behavior. Do not overwrite or
  revert unrelated working-tree changes.
- Preserve `Article.url` uniqueness and the crawler's duplicate-safe behavior.
  Retries, resumed tasks, and duplicate job delivery must not create duplicate
  articles or corrupt account statistics.
- Keep task state transitions and progress evidence intact: `CrawlTask`,
  `CrawlTaskAccount`, `CrawlLog`, and `WechatContentDownloadTask` are
  operational records, not disposable UI state.
- Enqueue work only after required database records are committed. Jobs must be
  safe when delivered late or more than once.
- Do not move long-running crawler work into an HTTP request. UI actions should
  create a task and enqueue a job; the job owns network crawling.
- Preserve platform-specific rate limits, error thresholds, pause/resume
  checks, pagination behavior, and configured daily budgets.
- `MonitorPage`, `MonitorPageVersion`, and `MonitorChange` belong to website
  monitoring. Do not apply their semantics to other account types without a
  deliberate product and migration change.
- Store raw upstream payloads only where the existing model contract expects
  them. Preserve enough provenance to distinguish missing upstream values from
  parser-derived values.

## Credentials, Authentication, and External Services

- Never commit, print, or place into fixtures real cookies, API keys, QR login
  sessions, OAuth tokens, database URLs, Feishu secrets, or `master.key`.
- Runtime crawler configuration is generally stored in `Option`; deployment
  secrets are injected from `.kamal/secrets`. Treat both as sensitive.
- WeChat MP sessions, WeRead account pools, Rednote/TikHub keys, Twitter `ct0`
  and `auth_token` cookies, proxies, and third-party API responses must not be
  exposed in logs, error messages, docs, or test output.
- MCP supports OAuth 2.1 and bearer API-key access. Keep authorization scopes,
  resource/audience validation, PKCE, token hashing, and write-tool access
  checks intact. Do not authorize writes from client-supplied identities alone.
- External API failures must leave a truthful, reviewable task or account
  failure state. Do not report success when the provider response is unknown.

## Architecture Boundaries

- `app/models`: persistence, validations, associations, and durable state
  transitions.
- `app/jobs`: asynchronous boundaries such as crawl execution, article-content
  downloads, periodic checks, and cleanup. Production uses Solid Queue.
- `lib/base_crawler.rb` and `lib/*_crawler.rb`: platform crawling behavior.
  API clients and shared retry/rate-limit behavior also live in `lib/`.
- `app/services`: imports, QR login orchestration, account resolution, and MCP
  OAuth services. Keep controllers thin.
- `app/controllers/admin`: authenticated administration. `app/controllers/api`:
  API-key protected endpoints. `app/controllers/mcp_controller.rb` and
  `app/mcp_server`: MCP transport and tools.
- `config/recurring.yml`: scheduled job definitions. Changes here need special
  care because they affect production crawling volume and external API usage.
- `config/deploy.yml` and `Dockerfile`: Kamal single-server deployment. The
  production image installs the `twitter-api-client` Python package under
  `/rails/vendor/python`; keep its dependency compatibility explicit.

## Data and Platform Invariants

- `Account#crawl!` creates a `CrawlTask` and enqueues `CrawlJob`; it must not
  synchronously perform the crawl in the request path.
- `CrawlJob` delegates to `CrawlOrchestrator` and subsequently enqueues
  `WechatContentDownloadJob`. Maintain this separation: WeChat article-list
  acquisition and article-body download have different rate-limit and failure
  behavior.
- A new account platform needs an STI subclass implementing `.crawler_class`,
  a crawler derived from `BaseCrawler`, importer/API integration as applicable,
  and tests covering dispatch and failure behavior.
- Website discovery depends on sitemap/robots behavior and monitored URLs;
  website fetch errors should be represented accurately rather than silently
  treated as an empty feed.
- Validate parsed timestamps before persistence. Missing or invalid source time
  values must remain `nil` or be handled explicitly, never silently become the
  Unix epoch.
- Do not introduce unbounded concurrency. Respect configured account/article
  concurrency and platform-specific rate limits.

## Tests and Validation

This project uses Rails' Minitest suite under `test/` rather than RSpec.
Choose the smallest meaningful validation first, then broaden as needed.

- Focused test: `bin/rails test test/models/account_test.rb`
- Focused library test: `bin/rails test test/lib/article_synchronizer_test.rb`
- Full test suite: `bin/rails test`
- Autoloading: `bin/rails zeitwerk:check`
- Lint: `bin/rubocop`
- Security checks: `bin/brakeman` and `bundle exec bundle-audit check`
- Prepare a disposable test database when schema changes: `RAILS_ENV=test bin/rails db:prepare`

For crawler, API-client, job, authentication, OAuth, or configuration changes,
add tests that prove both the successful path and the relevant failure or retry
invariant. Stub external HTTP/Python-provider calls; do not depend on live
credentials or external services in the test suite.

## Local Development and Deployment

- Install Ruby dependencies with `bundle install` using the Ruby version in
  `.ruby-version`.
- Start development services with `bin/dev`; it runs Rails and Tailwind watch.
- Use `bin/rails console` for local inspection, but remember development's
  Active Job adapter may execute async jobs in-process. Do not infer production
  Solid Queue behavior solely from console output.
- Deploy with Kamal configuration in `config/deploy.yml`. Do not edit or expose
  `.kamal/secrets`; validate deployment changes separately from application
  behavior.
- `tmp/` is for local investigative scripts and generated notes. Put generated
  analysis and onboarding documents in `tmp/doc/`; keep scripts and runtime
  artifacts outside that directory. Do not add temporary artifacts to version
  control unless the user explicitly requests a durable document elsewhere.

## Review Priorities

Prioritize concrete operational and security risks:

1. leaked credentials, weakened authentication, or MCP/API authorization gaps
2. duplicate or unbounded external crawling and rate-limit violations
3. incorrect article association, URL deduplication, timestamp, or task-state
   persistence
4. lost pause/resume, retry, error, or audit evidence during job processing
5. production scheduler, queue, Docker, or deployment changes that alter the
   runtime execution model
6. tests that do not establish the changed crawler or authorization invariant

De-prioritize formatting and subjective style feedback unless it hides a real
maintenance or correctness issue.
