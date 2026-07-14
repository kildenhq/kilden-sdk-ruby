$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "kilden"
require "minitest/autorun"
require "json"
require "zlib"
require "stringio"

# Path to the kilden-sdk-spec checkout (vectors + mock server).
SPEC_DIR = ENV.fetch("KILDEN_SPEC_DIR", File.expand_path("../../kilden-sdk-spec", __dir__))

# Scriptable transport for unit tests: replays queued responses and records
# every request (url, raw body, headers, decoded JSON).
class FakeTransport
  Request = Struct.new(:url, :body, :headers, keyword_init: true) do
    def json
      raw = headers["Content-Encoding"] == "gzip" ? Zlib.gunzip(body) : body
      JSON.parse(raw)
    end
  end

  attr_reader :requests

  def initialize
    @responses = []
    @requests = []
  end

  def respond(status:, headers: {}, body: '{"status":"ok"}')
    @responses << Kilden::Transport::Response.new(status: status, headers: headers, body: body)
    self
  end

  def respond_network_error
    @responses << Kilden::Transport::Response.new(status: 0, headers: {}, body: "", error: Errno::ECONNREFUSED.new)
    self
  end

  def post(url, body, headers)
    @requests << Request.new(url: url, body: body, headers: headers)
    @responses.shift || Kilden::Transport::Response.new(status: 200, headers: {}, body: '{"status":"ok"}')
  end
end

# Captures SDK log lines for assertions (implements the 4-method logging
# interface the client accepts).
class CapturedLogger
  def initialize
    @lines = []
  end

  %i[debug info warn error].each do |level|
    define_method(level) { |message| @lines << "#{level}: #{message}" }
  end

  def output
    @lines.join("\n")
  end
end

# Silent logger for integration tests.
class NullLog
  %i[debug info warn error].each { |level| define_method(level) { |_message| } }
end

module ClientHelpers
  NO_SLEEP = ->(_seconds) {}

  def build_client(**overrides)
    defaults = {
      transport: (@transport = FakeTransport.new),
      logger: (@log = CapturedLogger.new),
      flush_at: 1000, flush_interval: 3600
    }
    Kilden::Client.new("sk_test_secret", **defaults.merge(overrides))
  end

  def sent_events
    @transport.requests.select { |r| r.url.end_with?("/capture") }.flat_map { |r| r.json["batch"] }
  end
end
