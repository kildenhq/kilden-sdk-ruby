# frozen_string_literal: true

require "net/http"
require "uri"

module Kilden
  # Transport seam: anything responding to
  # +post(url, body, headers) -> Kilden::Transport::Response+ can replace the
  # default. A transport never raises — network failures come back as
  # status 0 so the retry loop can treat them uniformly.
  # @api private
  module Transport
    Response = Struct.new(:status, :headers, :body, :error, keyword_init: true) do
      def network_error?
        status.zero?
      end
    end

    # Default transport on Net::HTTP. One connection per request: the SDK
    # flushes at most every few seconds, so pooling buys nothing and costs
    # state that would go stale across forks.
    class NetHttp
      def initialize(timeout:)
        @timeout = timeout
      end

      def post(url, body, headers)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout if http.respond_to?(:write_timeout=)

        response = http.post(uri.path.empty? ? "/" : uri.path, body, headers)
        normalized = {}
        response.each_header { |k, v| normalized[k.downcase] = v }
        payload = response.body.to_s
        # A body shorter than Content-Length is a connection cut mid-response
        # (Net::HTTP returns the partial read silently). Malformed HTTP is a
        # network error per SPEC §4.3, so the batch retries.
        declared = normalized["content-length"]&.to_i
        if declared && payload.bytesize < declared
          return Response.new(status: 0, headers: normalized, body: payload,
                              error: EOFError.new("response truncated at #{payload.bytesize}/#{declared} bytes"))
        end
        Response.new(status: response.code.to_i, headers: normalized, body: payload)
      rescue StandardError => e
        Response.new(status: 0, headers: {}, body: "", error: e)
      ensure
        begin
          http&.finish if http&.started?
        rescue StandardError
          nil
        end
      end
    end
  end
end
