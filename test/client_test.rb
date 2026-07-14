require_relative "test_helper"

class ClientConstructionTest < Minitest::Test
  def test_requires_a_write_key
    assert_raises(Kilden::ConfigurationError) { Kilden::Client.new(nil) }
    assert_raises(Kilden::ConfigurationError) { Kilden::Client.new("") }
  end

  def test_rejects_public_keys_with_a_teaching_error
    error = assert_raises(Kilden::ConfigurationError) { Kilden::Client.new("wk_something_public") }
    assert_match(/secret key/, error.message)
    assert_match(/browser/, error.message)
  end

  def test_disabled_client_is_a_full_noop
    client = Kilden::Client.new("sk_test", enabled: false)
    client.track("u1", "e1")
    client.identify("u1", { "plan" => "pro" })
    client.alias("a", "b")
    client.flush
    assert_equal false, client.enabled?("f", "u1")
    assert_equal "x", client.feature_flag("f", "u1", default: "x")
    assert_equal 0, client.dropped_count
    client.close
  end
end

class ClientTrackTest < Minitest::Test
  include ClientHelpers

  def test_track_builds_the_wire_event
    client = build_client
    client.track("user_42", "order_completed", { "revenue" => 99.9 }, timestamp: "2026-01-02T03:04:05.678Z")
    client.flush

    event = sent_events.fetch(0)
    assert_equal "order_completed", event["event"]
    assert_equal "user_42", event["distinct_id"]
    assert_equal({ "revenue" => 99.9 }, event["properties"])
    assert_equal "2026-01-02T03:04:05.678Z", event["timestamp"]
    assert_match Kilden::UUID::V7, event["uuid"]
  end

  def test_batch_envelope_shape
    client = build_client
    client.track("u1", "e1")
    client.flush

    body = @transport.requests.fetch(0).json
    assert_equal %w[write_key sent_at batch], body.keys
    assert_equal "sk_test_secret", body["write_key"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, body["sent_at"])
  end

  def test_explicit_uuid_is_sent_verbatim
    client = build_client
    client.track("u1", "e1", {}, uuid: "0197FA10-7A2B-4C3D-8E4F-5A6B7C8D9E0F")
    client.flush
    assert_equal "0197FA10-7A2B-4C3D-8E4F-5A6B7C8D9E0F", sent_events.fetch(0)["uuid"]
  end

  def test_time_object_timestamps_are_formatted_utc_ms
    client = build_client
    client.track("u1", "e1", {}, timestamp: Time.utc(2026, 1, 2, 3, 4, 5, 678_000))
    client.flush
    assert_equal "2026-01-02T03:04:05.678Z", sent_events.fetch(0)["timestamp"]
  end

  def test_invalid_inputs_drop_with_a_warning_and_never_raise
    client = build_client
    client.track("", "event")
    client.track("u1", "")
    client.track(42, "event")
    client.track("u1", :event)
    client.track("u1", "x" * 201)
    client.track("x" * 513, "event")
    client.track("u1", "e", "not a hash")
    client.track("u1", "e", {}, timestamp: "garbage")
    client.track("u1", "e", {}, uuid: "garbage")
    client.flush

    assert_empty sent_events
    assert_match(/dropped/, @log.output)
  end

  def test_dollar_prefix_warns_in_debug_but_sends
    client = build_client(debug: true)
    client.track("u1", "$custom_event", { "$custom_prop" => 1 })
    client.flush

    assert_equal 1, sent_events.size
    assert_match(/reserved/, @log.output)
  end

  def test_identify_wraps_traits_in_set
    client = build_client
    client.identify("user_42", { "plan" => "pro" })
    client.identify("user_43")
    client.flush

    assert_equal({ "$set" => { "plan" => "pro" } }, sent_events.fetch(0)["properties"])
    assert_equal "$identify", sent_events.fetch(0)["event"]
    assert_equal({ "$set" => {} }, sent_events.fetch(1)["properties"])
  end

  def test_alias_wire_shape
    client = build_client
    client.alias("anon_0190a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b", "user_42")
    client.flush

    event = sent_events.fetch(0)
    assert_equal "$alias", event["event"]
    assert_equal "anon_0190a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b", event["distinct_id"]
    assert_equal({ "$alias" => "user_42" }, event["properties"])
  end

  def test_alias_requires_both_ids
    client = build_client
    client.alias("", "user_42")
    client.alias("user_42", "")
    client.flush
    assert_empty sent_events
  end

  def test_queue_full_drops_the_new_event
    client = build_client(max_queue_size: 3)
    5.times { |i| client.track("u1", "e#{i}") }
    assert_equal 2, client.dropped_count
    client.flush

    assert_equal %w[e0 e1 e2], sent_events.map { |e| e["event"] }
  end

  def test_after_close_events_drop_with_warning
    client = build_client
    client.close
    client.track("u1", "late")
    client.close # idempotent
    assert_match(/closed/, @log.output)
    assert_empty sent_events
  end

  def test_flush_chunks_batches_of_1000
    client = build_client(max_queue_size: 3000)
    1500.times { |i| client.track("u1", "e#{i}") }
    client.flush

    sizes = @transport.requests.map { |r| r.json["batch"].size }
    assert_equal [1000, 500], sizes
  end
end

class ClientFlagsTest < Minitest::Test
  include ClientHelpers

  def flags_response(flags)
    JSON.generate({ "flags" => flags, "sessionRecording" => { "enabled" => false, "sampleRate" => 0 } })
  end

  def test_flag_lookup_and_truthiness
    client = build_client
    @transport.respond(status: 200, body: flags_response("on" => true, "off" => false, "exp" => "variant_b"))

    assert_equal true, client.enabled?("on", "u1")
    # Cached: no extra request for the same distinct_id.
    assert_equal false, client.enabled?("off", "u1")
    assert_equal true, client.enabled?("exp", "u1")
    assert_equal "variant_b", client.feature_flag("exp", "u1")
    assert_equal 1, @transport.requests.size

    request = @transport.requests.fetch(0)
    assert request.url.end_with?("/decide")
    assert_equal({ "write_key" => "sk_test_secret", "distinct_id" => "u1" }, request.json)
  end

  def test_unknown_flag_returns_default
    client = build_client
    @transport.respond(status: 200, body: flags_response({}))
    assert_equal true, client.enabled?("ghost", "u1", default: true)
    assert_equal "fallback", client.feature_flag("ghost", "u1", default: "fallback")
  end

  def test_person_properties_bypass_the_cache
    client = build_client
    @transport.respond(status: 200, body: flags_response("f" => true))
    @transport.respond(status: 200, body: flags_response("f" => false))
    @transport.respond(status: 200, body: flags_response("f" => true))

    assert_equal true, client.enabled?("f", "u1")
    assert_equal false, client.enabled?("f", "u1", person_properties: { "plan" => "free" })
    assert_equal({ "person_properties" => { "plan" => "free" } },
                 @transport.requests.fetch(1).json.slice("person_properties"))
    # The bypassed response was not cached; the cached original still serves.
    assert_equal true, client.enabled?("f", "u1")
    assert_equal 2, @transport.requests.size
  end

  def test_failures_return_default_without_raising
    client = build_client
    @transport.respond(status: 500, body: "boom")
    assert_equal "safe", client.feature_flag("f", "u1", default: "safe")

    @transport.respond(status: 200, body: "not json")
    assert_equal true, client.enabled?("f", "u2", default: true)

    @transport.respond_network_error
    assert_equal false, client.enabled?("f", "u3")
  end

  def test_flag_input_validation
    client = build_client
    assert_equal false, client.enabled?("", "u1")
    assert_equal "d", client.feature_flag("f", "", default: "d")
    assert_empty @transport.requests
  end
end
