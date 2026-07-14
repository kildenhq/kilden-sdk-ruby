# Minimal Rack app for the fork-safety integration test. Booted with
# `puma -w 2 --preload`: the client is built (and its queue seeded) in the
# master process BEFORE the workers fork, which is exactly the scenario
# contract 9 exists for.
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "kilden"

client = Kilden::Client.new(
  "sk_test_secret",
  host: ENV.fetch("KILDEN_MOCK_HOST"),
  flush_at: 50, flush_interval: 0.3,
  logger: Kilden::Log.new(:error)
)

# Seed events into the master's queue without waking the worker thread —
# the frozen inherited state a preforked child must discard, not resend.
queue = client.instance_variable_get(:@queue)
3.times { |i| queue.push({ "uuid" => Kilden::UUID.v7, "event" => "inherited",
                           "distinct_id" => "master", "properties" => { "i" => i },
                           "timestamp" => Kilden::Client.format_time(Time.now) }) }

run lambda { |env|
  if env["PATH_INFO"] == "/health"
    [200, { "content-type" => "text/plain" }, ["healthy"]]
  else
    client.track("worker_#{Process.pid}", "hit", { "pid" => Process.pid })
    [200, { "content-type" => "text/plain" }, ["ok #{Process.pid}"]]
  end
}
