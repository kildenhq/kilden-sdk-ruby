require_relative "../test_helper"
require "net/http"

# Boots the spec repo's mock capture server (Go) once for the whole
# integration suite. Needs Go and the kilden-sdk-spec checkout (KILDEN_SPEC_DIR).
module MockServer
  PORT = Integer(ENV.fetch("KILDEN_MOCK_PORT", 8094))
  HOST = "http://127.0.0.1:#{PORT}".freeze

  module_function

  def start
    return if defined?(@pid) && @pid

    dir = File.join(SPEC_DIR, "mockserver")
    raise "kilden-sdk-spec checkout not found at #{SPEC_DIR} (set KILDEN_SPEC_DIR)" unless File.directory?(dir)

    @pid = Process.spawn("go", "run", ".", "-addr", ":#{PORT}",
                         chdir: dir, out: File::NULL, err: File::NULL)
    at_exit do
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    rescue StandardError
      nil
    end

    100.times do
      Net::HTTP.get(URI("#{HOST}/healthz"))
      return
    rescue StandardError
      sleep 0.2
    end
    raise "mock server did not become healthy on #{HOST}"
  end

  def reset
    post("/__mock/reset", {})
  end

  def post(path, body)
    uri = URI("#{HOST}#{path}")
    response = Net::HTTP.post(uri, JSON.generate(body), "Content-Type" => "application/json")
    raise "#{path} -> #{response.code}" unless response.code == "200"
  end

  def captured
    JSON.parse(Net::HTTP.get(URI("#{HOST}/__mock/captured")))
  end

  def captured_events
    captured.fetch("events") || []
  end
end

MockServer.start

module IntegrationHelpers
  UUID_V7 = /\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  ISO_MS = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/

  def quiet_logger
    NullLog.new
  end

  def live_client(**overrides)
    defaults = { host: MockServer::HOST, flush_at: 1000, flush_interval: 3600, logger: quiet_logger }
    Kilden::Client.new("sk_test_secret", **defaults.merge(overrides))
  end
end
