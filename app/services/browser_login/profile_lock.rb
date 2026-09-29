# frozen_string_literal: true

module BrowserLogin
  # Chrome 每个 user-data-dir 同时只能被一个实例使用（Chrome 自身也会加锁，
  # 但失败是静默的）。用 flock 把「谁在用这个 profile」变成内核级事实：
  # Session 人工登录期间、WechatArticleBrowserFetcher 正文抓取期间各持锁，
  # 互相排除，避免拉起第二个同 profile 的 Chrome 造成难以排查的失败。
  #
  # 进程死亡时内核自动释放锁，不会死锁；跨 Puma worker / 跨进程同样有效。
  class ProfileLock
    LOCK_FILENAME = ".profile.lock"

    # @param timeout [Number] 等待锁的最长秒数（0 = 立即失败）
    # @raise [BrowserLogin::Error] 锁被占用
    def self.acquire(profile_dir, timeout: 5)
      FileUtils.mkdir_p(profile_dir)
      file = File.open(File.join(profile_dir, LOCK_FILENAME), File::CREAT | File::RDWR)
      deadline = Time.current + timeout
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        raise Error, "浏览器环境正被占用（人工登录或正文抓取进行中），请稍后再试"
      end
      new(file)
    rescue BrowserLogin::Error
      raise
    rescue StandardError => e
      file&.close
      raise Error, "获取浏览器环境锁失败：#{e.class}: #{e.message}"
    end

    def initialize(file)
      @file = file
    end

    def release
      @file.flock(File::LOCK_UN)
      @file.close
    rescue StandardError
      nil
    end
  end
end
