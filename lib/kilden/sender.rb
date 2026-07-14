# frozen_string_literal: true

require "json"
require "zlib"

module Kilden
  # Owns one batch from build to success or exhaustion (spec §4.3). Failed
  # batches never go back into the main queue — that would shuffle ordering
  # and could evict fresh events.
  # @api private
  class Sender
    MAX_RETRIES = 3
    GZIP_THRESHOLD = 1024

    attr_reader :dropped_count

    def initialize(write_key:, host:, transport:, logger:, sleeper: nil, rng: Random.new)
      @write_key = write_key
      @capture_url = "#{host.chomp('/')}/capture"
      @transport = transport
      @logger = logger
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @rng = rng
      @dropped = 0
      @mutex = Mutex.new
    end

    def dropped!(count)
      @mutex.synchronize { @dropped += count }
    end

    def dropped_total
      @mutex.synchronize { @dropped }
    end

    # Sends up to MAX_RETRIES + 1 attempts. deadline (monotonic seconds) cuts
    # the loop short during shutdown: telemetry never hangs a process.
    def send_batch(events, deadline: nil)
      return :ok if events.empty?

      attempt = 0
      loop do
        response = deliver(events)
        return :ok if success?(response)

        unless retryable?(response)
          drop(events,
               "kilden: dropped #{events.size} events (HTTP #{response.status}: #{response.body.to_s.strip[0, 120]})")
          return :dropped
        end

        attempt += 1
        if attempt > MAX_RETRIES || past?(deadline)
          drop(events, "kilden: dropped #{events.size} events after #{attempt} attempts")
          return :dropped
        end

        delay = backoff(attempt, response)
        if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) + delay > deadline
          drop(events, "kilden: dropped #{events.size} events (shutdown deadline)")
          return :dropped
        end
        @sleeper.call(delay)
      end
    end

    private

    def deliver(events)
      # sent_at is stamped when the request is built (clock-skew correction
      # happens server-side against this value).
      payload = {
        "write_key" => @write_key,
        "sent_at" => Client.format_time(Time.now),
        "batch" => events
      }
      body = JSON.generate(payload)
      headers = {
        "Content-Type" => "application/json",
        "User-Agent" => "kilden-ruby/#{VERSION}"
      }
      if body.bytesize > GZIP_THRESHOLD
        body = Zlib.gzip(body)
        headers["Content-Encoding"] = "gzip"
      end
      @transport.post(@capture_url, body, headers)
    end

    def success?(response)
      # Any 2xx is success — the response body is never parsed; the status
      # is the whole signal (§4.3).
      (200..299).cover?(response.status)
    end

    def retryable?(response)
      response.network_error? || response.status == 429 || response.status >= 500
    end

    def backoff(retry_number, response)
      if response.status == 429 && (after = response.headers["retry-after"]) && after.to_i.positive?
        return after.to_i
      end

      base = [0.5 * (2**(retry_number - 1)), 30].min
      base * @rng.rand(0.5..1.5)
    end

    def past?(deadline)
      deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end

    def drop(events, message)
      dropped!(events.size)
      @logger.warn(message)
    end
  end
end
