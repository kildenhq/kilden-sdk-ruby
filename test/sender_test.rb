# frozen_string_literal: true

require_relative "test_helper"

class SenderTest < Minitest::Test
  EVENT = {
    "uuid" => "0197fa10-7a2b-7c3d-8e4f-5a6b7c8d9e0f",
    "event" => "e", "distinct_id" => "u1", "properties" => {},
    "timestamp" => "2026-07-14T12:00:00.000Z"
  }.freeze

  def build_sender(rng: Random.new(42))
    @transport = FakeTransport.new
    @log = CapturedLogger.new
    @sleeps = []
    Kilden::Sender.new(
      write_key: "sk_test_secret", host: "http://mock.local",
      transport: @transport, logger: @log,
      sleeper: ->(s) { @sleeps << s }, rng: rng
    )
  end

  def test_success_on_first_attempt
    sender = build_sender

    assert_equal :ok, sender.send_batch([EVENT])
    assert_equal 1, @transport.requests.size
    assert_empty @sleeps
  end

  def test_429_honors_retry_after_exactly
    sender = build_sender
    @transport.respond(status: 429, headers: { "retry-after" => "3" }, body: "Too Many Requests")

    assert_equal :ok, sender.send_batch([EVENT])
    assert_equal [3], @sleeps
    assert_equal 2, @transport.requests.size
  end

  def test_retryable_failures_back_off_with_jitter
    sender = build_sender
    @transport.respond(status: 500, body: "boom")
    @transport.respond_network_error
    @transport.respond(status: 503, body: "still booting")

    assert_equal :ok, sender.send_batch([EVENT])

    assert_equal 4, @transport.requests.size
    assert_equal 3, @sleeps.size
    [0.5, 1.0, 2.0].each_with_index do |base, i|
      assert_in_delta base, @sleeps[i] / 1.0, (base * 0.5) + 0.001,
                      "retry #{i + 1} outside jitter window"
    end
  end

  def test_corrupt_body_on_2xx_is_success
    # SPEC §4.3: any 2xx is success — the body is never parsed.
    sender = build_sender
    @transport.respond(status: 200, body: "corrupt {{{")

    assert_equal :ok, sender.send_batch([EVENT])
    assert_equal 1, @transport.requests.size
    assert_empty @sleeps
  end

  def test_exhaustion_drops_and_counts
    sender = build_sender
    4.times { @transport.respond(status: 503, body: "unavailable") }

    assert_equal :dropped, sender.send_batch([EVENT, EVENT])
    assert_equal 4, @transport.requests.size # 1 + 3 retries
    assert_equal 2, sender.dropped_total
    assert_match(/dropped 2 events/, @log.output)
  end

  %w[400 401 403 413].each do |status|
    define_method("test_#{status}_is_terminal") do
      sender = build_sender
      @transport.respond(status: Integer(status), body: "nope")

      assert_equal :dropped, sender.send_batch([EVENT])
      assert_equal 1, @transport.requests.size
      assert_empty @sleeps
      assert_equal 1, sender.dropped_total
    end
  end

  def test_gzips_large_bodies_only
    sender = build_sender
    sender.send_batch([EVENT])

    refute_equal "gzip", @transport.requests.fetch(0).headers["Content-Encoding"]

    big = EVENT.merge("properties" => { "blob" => "x" * 2000 })
    sender.send_batch([big])
    request = @transport.requests.fetch(1)

    assert_equal "gzip", request.headers["Content-Encoding"]
    assert_equal "x" * 2000, request.json["batch"][0]["properties"]["blob"]
  end

  def test_user_agent_and_content_type
    sender = build_sender
    sender.send_batch([EVENT])
    headers = @transport.requests.fetch(0).headers

    assert_equal "application/json", headers["Content-Type"]
    assert_equal "kilden-ruby/#{Kilden::VERSION}", headers["User-Agent"]
  end

  def test_shutdown_deadline_cuts_retries
    sender = build_sender
    4.times { @transport.respond(status: 503, body: "unavailable") }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.01

    assert_equal :dropped, sender.send_batch([EVENT], deadline: deadline)
    assert_operator @transport.requests.size, :<=, 2
    assert_match(/deadline|attempts/, @log.output)
  end
end
