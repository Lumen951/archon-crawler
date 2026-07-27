# frozen_string_literal: true

# General-purpose sliding window rate limiter.
#
# Thread-safe (Mutex) and fiber-safe (works with Async — sleep yields to the reactor).
#
# Usage:
#   limiter = RateLimiter.new(60, 60)   # 60 requests per 60 seconds
#   limiter.wait                         # blocks until a slot is available
#
# For different endpoints, create separate instances:
#   download_limiter = RateLimiter.new(60, 60)
#   search_limiter   = RateLimiter.new(10, 10)
#
class RateLimiter
  # @param limit  [Integer] max requests allowed in the window
  # @param window [Integer] window size in seconds
  def initialize(limit, window)
    @limit  = limit
    @window = window
    @timestamps = []
    @mutex = Mutex.new
  end

  # Block until a request slot is available.
  # In an Async context, sleep yields to the reactor so other fibers proceed.
  def wait
    loop do
      sleep_for = @mutex.synchronize do
        prune
        if @timestamps.size >= @limit
          # Window full — sleep until the oldest request expires
          (@timestamps.first + @window - Process.clock_gettime(Process::CLOCK_MONOTONIC)).clamp(0, @window)
        else
          @timestamps << Process.clock_gettime(Process::CLOCK_MONOTONIC)
          0
        end
      end

      break if sleep_for.zero?
      sleep(sleep_for)
    end
  end

  # Number of remaining request slots in the current window.
  def remaining
    @mutex.synchronize do
      prune
      @limit - @timestamps.size
    end
  end

  # Clear all recorded timestamps (useful for testing).
  def reset!
    @mutex.synchronize { @timestamps.clear }
  end

  private

  # Remove timestamps older than the window.
  def prune
    cutoff = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @window
    @timestamps.shift while @timestamps.any? && @timestamps.first < cutoff
  end
end
