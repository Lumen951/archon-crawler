require "test_helper"

class BrowserLoginCookieExportTest < ActiveSupport::TestCase
  # Ferrum::Cookies::Cookie 替身：to_h 返回 CDP 的字符串键原始属性
  SnapshotCookie = Struct.new(:name, :value, :domain, :path, :expires, :httpOnly, :secure, :sameSite) do
    def to_h
      { "name" => name, "value" => value, "domain" => domain, "path" => path,
        "expires" => expires, "httpOnly" => httpOnly, "secure" => secure, "sameSite" => sameSite }
    end
  end

  test "serialize keeps only target-domain cookies with minimal settable attrs" do
    cookies = [
      SnapshotCookie.new("slave_sid", "s", ".qq.com", "/", 0, true, true, "Lax"),
      SnapshotCookie.new("junk", "j", ".example.com", "/", 0, false, false, nil),
      SnapshotCookie.new("empty", "", ".qq.com", "/", 0, false, false, nil)
    ]

    entries = JSON.parse(BrowserLogin::CookieExport.serialize(cookies, domain_pattern: /qq\.com\z/))

    assert_equal [ "slave_sid" ], entries.map { |e| e["name"] }, "外域与空值 Cookie 必须剔除"
    assert_equal({
      "name" => "slave_sid", "value" => "s", "domain" => ".qq.com", "path" => "/",
      "httpOnly" => true, "secure" => true, "sameSite" => "Lax"
    }, entries.first, "只保留 Network.setCookie 接受的字段（size/session 等只读字段不导出）")
  end

  # 会话级 Cookie（expires=0）不带 expires 回灌，保持其会话语义；
  # 持久 Cookie 保留过期时间
  test "serialize keeps session cookies session-scoped and persistent cookies with expiry" do
    cookies = [
      SnapshotCookie.new("verify", "v", ".qq.com", "/", 0, false, true, nil),
      SnapshotCookie.new("kept", "k", ".qq.com", "/x", 1_800_000_000.5, false, false, "None")
    ]

    entries = JSON.parse(BrowserLogin::CookieExport.serialize(cookies))

    assert_not entries[0].key?("expires"), "会话级 Cookie 不得被写成持久 Cookie"
    assert_equal 1_800_000_000, entries[1]["expires"]
    assert_equal "/x", entries[1]["path"]
  end

  test "save and load round-trip through the profile dir with restrictive perms" do
    Dir.mktmpdir do |tmp_root|
      profile_dir = File.join(tmp_root, "wechat_mp")
      json = BrowserLogin::CookieExport.serialize(
        [ SnapshotCookie.new("slave_user", "u", ".qq.com", "/", 0, false, false, nil) ]
      )

      assert_equal 1, BrowserLogin::CookieExport.save(profile_dir, json)
      assert_equal 0600, File.stat(BrowserLogin::CookieExport.path_for(profile_dir)).mode & 0777

      entries = BrowserLogin::CookieExport.load(profile_dir)
      assert_equal "slave_user", entries.first["name"]
      assert_equal "u", entries.first["value"]
    end
  end

  # 快照缺失/损坏都不是致命错误：独立浏览器照样能拉起来，只是少了回灌
  test "load returns an empty list for missing or corrupt snapshots" do
    Dir.mktmpdir do |tmp_root|
      assert_empty BrowserLogin::CookieExport.load(tmp_root)

      corrupt = File.join(tmp_root, "wechat_mp")
      FileUtils.mkdir_p(corrupt)
      File.write(BrowserLogin::CookieExport.path_for(corrupt), "{not json")
      assert_empty BrowserLogin::CookieExport.load(corrupt)
    end
  end

  test "load drops entries without name, value or domain" do
    Dir.mktmpdir do |tmp_root|
      File.write(
        BrowserLogin::CookieExport.path_for(tmp_root),
        [ { "name" => "ok", "value" => "v", "domain" => ".qq.com" },
          { "name" => "no_value", "value" => "", "domain" => ".qq.com" },
          { "name" => "no_domain", "value" => "v" },
          "not-a-hash" ].to_json
      )

      entries = BrowserLogin::CookieExport.load(tmp_root)
      assert_equal [ "ok" ], entries.map { |e| e["name"] }
    end
  end
end
