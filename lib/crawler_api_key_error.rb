# Marker module for "API key missing/expired" errors raised by any platform's
# API client (WechatApiClient, RednoteApiClient, future TwitterApiClient, ...).
#
# Each platform-specific error class should `include CrawlerApiKeyError` so
# that shared code (Retryable, CrawlOrchestrator) can detect and react to
# these errors generically, without needing an explicit list of every
# platform's error classes. For example:
#
#   class ApiKeyExpiredError < ApiError
#     include CrawlerApiKeyError
#   end
module CrawlerApiKeyError
end
