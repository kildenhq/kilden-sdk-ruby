require_relative "integration_helper"

# Contract 9 under a REAL preforking server: puma -w 2 --preload, client
# built and queue seeded in the master, workers must discard the inherited
# events, restart the dead worker thread, and deliver their own traffic
# exactly once.
class ForkSafetyTest < Minitest::Test
  PUMA_PORT = 9293
  REQUESTS = 20

  def test_preforked_puma_delivers_exactly_once_per_request
    MockServer.reset
    pid = spawn_puma
    begin
      wait_for_puma
      REQUESTS.times do |i|
        response = Net::HTTP.get_response(URI("http://127.0.0.1:#{PUMA_PORT}/?i=#{i}"))
        assert_equal "200", response.code
      end

      events = wait_for_events(REQUESTS)
      hits = events.select { |e| e["event"] == "hit" }
      inherited = events.select { |e| e["event"] == "inherited" }

      assert_equal REQUESTS, hits.size, "every request tracks exactly one event"
      assert_equal REQUESTS, hits.map { |e| e["uuid"] }.uniq.size, "no duplicate deliveries"

      pids = hits.map { |e| e["properties"]["pid"] }.uniq
      assert_operator pids.size, :>=, 2, "traffic must come from at least two preforked workers"

      # The master never flushed (its worker thread never started) and the
      # children discarded what they inherited: nothing leaks through.
      assert_empty inherited, "children must discard the queue inherited from the master"
    ensure
      stop_puma(pid)
    end
  end

  private

  def spawn_puma
    Process.spawn(
      { "KILDEN_MOCK_HOST" => MockServer::HOST },
      "bundle", "exec", "puma", "-w", "2", "--preload", "-b", "tcp://127.0.0.1:#{PUMA_PORT}",
      File.expand_path("../support/fork_app/config.ru", __dir__),
      out: File::NULL, err: File::NULL
    )
  end

  def wait_for_puma
    100.times do
      Net::HTTP.get(URI("http://127.0.0.1:#{PUMA_PORT}/health"))
      return
    rescue StandardError
      sleep 0.2
    end
    raise "puma did not boot"
  end

  def wait_for_events(minimum)
    events = []
    50.times do
      events = MockServer.captured_events
      break if events.count { |e| e["event"] == "hit" } >= minimum

      sleep 0.2
    end
    events
  end

  def stop_puma(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue StandardError
    nil
  end
end
