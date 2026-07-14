require_relative "integration_helper"

# Retry, compression and flag behavior against the real mock server,
# including its armed failure modes (spec §4.3, §10).
class LiveBehaviorTest < Minitest::Test
  include IntegrationHelpers

  EVENT = {
    "uuid" => "0197fa10-7a2b-7c3d-8e4f-5a6b7c8d9e0f",
    "event" => "live", "distinct_id" => "u1", "properties" => {},
    "timestamp" => "2026-07-14T12:00:00.000Z"
  }.freeze

  def setup
    MockServer.reset
    @sleeps = []
    @sender = Kilden::Sender.new(
      write_key: "sk_test_secret", host: MockServer::HOST,
      transport: Kilden::Transport::NetHttp.new(timeout: 1),
      logger: quiet_logger, sleeper: ->(s) { @sleeps << s }
    )
  end

  def test_429_retries_after_the_advertised_delay
    MockServer.post("/__mock/fail", { "times" => 2, "status" => 429, "retry_after" => 3 })
    assert_equal :ok, @sender.send_batch([EVENT])
    assert_equal [3, 3], @sleeps
    assert_equal 1, MockServer.captured_events.size
  end

  def test_401_is_terminal_no_retry
    sender = Kilden::Sender.new(
      write_key: "sk_who_is_this", host: MockServer::HOST,
      transport: Kilden::Transport::NetHttp.new(timeout: 1),
      logger: quiet_logger, sleeper: ->(s) { @sleeps << s }
    )
    assert_equal :dropped, sender.send_batch([EVENT])
    assert_empty @sleeps
    assert_empty MockServer.captured_events
  end

  def test_500_then_success
    MockServer.post("/__mock/fail", { "times" => 1, "status" => 500 })
    assert_equal :ok, @sender.send_batch([EVENT])
    assert_equal 1, @sleeps.size
    assert_equal 1, MockServer.captured_events.size
  end

  def test_corrupt_response_retries
    MockServer.post("/__mock/fail", { "times" => 1, "mode" => "corrupt" })
    assert_equal :ok, @sender.send_batch([EVENT])
    # The corrupt 200 was not trusted as delivery... but the mock DID process
    # nothing (failure replaced handling), so exactly one event landed.
    assert_equal 1, MockServer.captured_events.size
  end

  def test_cut_connection_retries
    MockServer.post("/__mock/fail", { "times" => 1, "mode" => "cut" })
    assert_equal :ok, @sender.send_batch([EVENT])
    assert_equal 1, MockServer.captured_events.size
  end

  def test_timeout_retries
    MockServer.post("/__mock/fail", { "times" => 1, "mode" => "timeout", "delay_ms" => 3000 })
    assert_equal :ok, @sender.send_batch([EVENT])
    assert_equal 1, MockServer.captured_events.size
  end

  def test_gzip_bodies_are_accepted_and_flagged
    client = live_client
    client.track("u1", "big_event", { "blob" => "x" * 4000 })
    client.flush

    batch = MockServer.captured.fetch("batches").fetch(0)
    assert batch["gzip"], "large body should have been gzipped"
    assert_equal "x" * 4000, batch["batch"][0]["properties"]["blob"]
  end

  def test_flags_end_to_end_with_cache
    MockServer.post("/__mock/flags", { "flags" => [
                      { "key" => "on_flag", "active" => true, "rollout_percentage" => 100 },
                      { "key" => "variant_flag_1", "active" => true, "rollout_percentage" => 100,
                        "variants" => [{ "key" => "control", "rollout_percentage" => 50 },
                                       { "key" => "test", "rollout_percentage" => 50 }] }
                    ] })
    client = live_client(timeout: 1)

    assert_equal true, client.enabled?("on_flag", "user_42")
    variant = client.feature_flag("variant_flag_1", "user_42")
    assert_includes %w[control test], variant

    # Cached: arm a failure — the cached answer still serves.
    MockServer.post("/__mock/fail", { "times" => 1, "status" => 500 })
    assert_equal true, client.enabled?("on_flag", "user_42")

    # person_properties bypasses the cache and eats the armed failure → default.
    assert_equal "fallback",
                 client.feature_flag("on_flag", "user_42",
                                     person_properties: { "plan" => "pro" }, default: "fallback")
  end

  def test_unknown_write_key_on_decide_returns_default
    client = Kilden::Client.new("sk_nobody", host: MockServer::HOST,
                                flush_at: 1000, flush_interval: 3600, logger: quiet_logger)
    assert_equal false, client.enabled?("anything", "u1")
  end
end
