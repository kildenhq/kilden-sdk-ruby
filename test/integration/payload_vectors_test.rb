require_relative "integration_helper"

# The spec §9 payload-vector runner: replay every call against the live mock
# and compare what it captured, field by field.
class PayloadVectorsTest < Minitest::Test
  include IntegrationHelpers

  DOC = JSON.parse(File.read(File.join(SPEC_DIR, "vectors", "payload.json")))

  DOC["vectors"].each do |vector|
    define_method("test_#{vector["name"]}") do
      MockServer.reset
      client = live_client
      replay(client, vector["call"])
      client.flush

      events = MockServer.captured_events
      if vector["expect"] == "discarded"
        assert_empty events, "expected the call to be discarded client-side"
        return
      end

      assert_equal 1, events.size, "expected exactly one captured event"
      compare(vector.fetch("expect_event"), events.fetch(0))
    end
  end

  private

  def replay(client, call)
    args = call.fetch("args")
    opts = (args["opts"] || {}).transform_keys(&:to_sym)
    case call.fetch("method")
    when "track"
      client.track(args["distinct_id"], args["event"], args["properties"] || {}, opts)
    when "identify"
      client.identify(args["distinct_id"], args["traits"] || {}, opts)
    when "alias"
      client.alias(args["previous_id"], args["distinct_id"])
    else
      flunk "unknown vector method #{call["method"]}"
    end
  end

  def compare(expected, actual)
    assert_equal expected["event"], actual["event"]
    assert_equal expected["distinct_id"], actual["distinct_id"]
    assert_equal expected["properties"], actual["properties"]

    if expected["uuid"] == "<uuid_v7>"
      assert_match UUID_V7, actual["uuid"]
    else
      assert_equal expected["uuid"], actual["uuid"]
    end

    if expected["timestamp"] == "<iso8601_utc_ms>"
      assert_match ISO_MS, actual["timestamp"]
    else
      assert_equal expected["timestamp"], actual["timestamp"]
    end
  end
end
