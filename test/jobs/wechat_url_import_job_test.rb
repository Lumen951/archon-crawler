require "test_helper"

class WechatUrlImportJobTest < ActiveJob::TestCase
  test "processes created, found, and failed URLs independently" do
    task = WechatUrlImportTask.create!(total_count: 3)
    items = 3.times.map { |i| task.items.create!(url: "https://mp.weixin.qq.com/s/#{i}") }
    created_account = WechatAccount.create!(fakeid: "job_created", nickname: "新帐号", status: :active)
    found_account = WechatAccount.create!(fakeid: "job_found", nickname: "已存在", status: :active)
    results = [
      AccountResolver::Result.new(accounts: [created_account], status: "created"),
      AccountResolver::Result.new(accounts: [found_account], status: "found"),
      AccountResolver::Result.new(accounts: [], status: "error", error: "链接无效")
    ]

    stub_class_method(AccountResolver, :resolve_wechat_by_url, ->(_url) { results.shift }) do
      WechatUrlImportJob.perform_now(task.id)
    end

    task.reload
    assert task.failed?
    assert_equal 3, task.processed_count
    assert_equal 1, task.created_count
    assert_equal 1, task.found_count
    assert_equal 1, task.failed_count
    assert_equal %w[created found failed], items.map { |item| item.reload.status }
  end

  test "continues after resolver exception" do
    task = WechatUrlImportTask.create!(total_count: 2)
    first, second = 2.times.map { |i| task.items.create!(url: "https://mp.weixin.qq.com/s/error-#{i}") }
    account = WechatAccount.create!(fakeid: "job_after_error", nickname: "后续帐号", status: :active)
    calls = 0

    stub_class_method(AccountResolver, :resolve_wechat_by_url, ->(_url) {
      calls += 1
      raise "网络超时" if calls == 1

      AccountResolver::Result.new(accounts: [account], status: "created")
    }) do
      WechatUrlImportJob.perform_now(task.id)
    end

    assert task.reload.failed?
    assert_equal 2, task.processed_count
    assert_equal "failed", first.reload.status
    assert_equal "created", second.reload.status
  end

  test "does not process a terminal task" do
    task = WechatUrlImportTask.create!(status: :completed, total_count: 1)
    task.items.create!(url: "https://mp.weixin.qq.com/s/terminal")

    called = false
    stub_class_method(AccountResolver, :resolve_wechat_by_url, ->(_url) { called = true }) do
      WechatUrlImportJob.perform_now(task.id)
    end

    assert_equal false, called
  end
end
