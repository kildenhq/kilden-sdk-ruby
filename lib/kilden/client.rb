require "json"
require "logger"
require "time"

module Kilden
  # The Kilden server-side client: bounded in-memory queue, background
  # worker, retries with backoff, remote feature flags. Construction is the
  # only place that raises (spec contract 2); after that every public method
  # is exception-safe — telemetry never takes down a request.
  #
  #   kilden = Kilden::Client.new(ENV["KILDEN_SECRET_KEY"])
  #   kilden.track("user_42", "order_completed", { "revenue" => 99.9 })
  #   kilden.close # on shutdown; an at_exit hook covers the forgetful
  class Client
    DEFAULT_HOST = "https://ingest.kilden.io"
    MAX_EVENT_BYTES = 200
    MAX_DISTINCT_ID_BYTES = 512
    BATCH_LIMIT = 1000
    CLOSE_DEADLINE = 10

    # dropped_count: events lost to a full queue or exhausted retries
    # (contract 7/8) — observable so operators can alert on it.
    def dropped_count
      return 0 unless @enabled

      @queue.dropped_count + @sender.dropped_total
    end

    def initialize(write_key, host: DEFAULT_HOST, flush_at: 20, flush_interval: 10,
                   max_queue_size: 10_000, timeout: 3, transport: nil, debug: false,
                   enabled: true, logger: nil)
      unless write_key.is_a?(String) && !write_key.empty?
        raise ConfigurationError, "a write key is required — find your project's secret key (sk_...) in the Kilden panel"
      end
      if write_key.start_with?("wk_")
        raise ConfigurationError,
              "#{write_key[0, 10]}… is a public write key. Server SDKs authenticate with the secret key (sk_...): " \
              "public keys degrade events to source=client and break verified revenue. " \
              "Never ship the secret key to a browser."
      end

      @debug = debug ? true : false
      @logger = logger || Logger.new($stderr, progname: "kilden", level: @debug ? Logger::DEBUG : Logger::WARN)
      @enabled = enabled ? true : false
      @flush_interval = flush_interval
      return unless @enabled

      @queue = EventQueue.new(max_size: max_queue_size, flush_at: flush_at)
      @sender = Sender.new(
        write_key: write_key,
        host: host,
        transport: transport || Transport::NetHttp.new(timeout: timeout),
        logger: @logger
      )
      @decide = Decide.new(write_key: write_key, host: host, timeout: timeout,
                           transport: transport, logger: @logger)
      @flag_cache = FlagCache.new
      @pid = Process.pid
      @worker = nil
      @lifecycle = Mutex.new
      @closed = false
      @shutdown_deadline = nil

      at_exit { close }
    end

    def track(distinct_id, event, properties = {}, opts = {})
      guard do
        next unless @enabled && open_for_events?

        payload = build_event(distinct_id, event, properties, opts)
        enqueue(payload) if payload
        nil
      end
    end

    def identify(distinct_id, traits = {}, opts = {})
      guard do
        next unless @enabled && open_for_events?

        traits = {} if traits.nil?
        unless traits.is_a?(Hash)
          @logger.warn("kilden: identify traits must be a Hash; event dropped")
          next
        end
        payload = build_event(distinct_id, "$identify", { "$set" => traits }, opts, reserved: true)
        enqueue(payload) if payload
        nil
      end
    end

    # `alias` is a Ruby keyword, so the method is defined dynamically; the
    # call site reads naturally: kilden.alias("anon_…", "user_42").
    define_method(:alias) do |previous_id, distinct_id|
      guard do
        next unless @enabled && open_for_events?

        unless valid_id?(distinct_id, "alias distinct_id")
          next
        end
        payload = build_event(previous_id, "$alias", { "$alias" => distinct_id }, {}, reserved: true)
        enqueue(payload) if payload
        nil
      end
    end

    def enabled?(flag_key, distinct_id, person_properties: nil, default: false)
      guard(default) do
        state, value = fetch_flag(flag_key, distinct_id, person_properties)
        next default unless state == :ok

        value == true || value.is_a?(String)
      end
    end

    def feature_flag(flag_key, distinct_id, person_properties: nil, default: false)
      guard(default) do
        state, value = fetch_flag(flag_key, distinct_id, person_properties)
        state == :ok ? value : default
      end
    end

    # Blocking: drains everything queued at this moment, retries included.
    def flush
      guard do
        next unless @enabled

        check_fork
        @queue.drain.each_slice(BATCH_LIMIT) { |batch| @sender.send_batch(batch) }
        nil
      end
    end

    # flush with a 10-second deadline, then worker shutdown. Idempotent;
    # events sent after close are dropped with a warning.
    def close
      guard do
        next unless @enabled

        @lifecycle.synchronize do
          next if @closed

          @closed = true
          @shutdown_deadline = monotonic + CLOSE_DEADLINE
          @queue.close
        end

        worker = @worker
        if worker&.alive?
          worker.join([@shutdown_deadline - monotonic, 0].max)
          if worker.alive?
            worker.kill
            abandoned = @queue.drain.size
            if abandoned.positive?
              @sender.dropped!(abandoned)
              @logger.warn("kilden: close deadline hit; dropped #{abandoned} events")
            end
          end
        else
          @queue.drain.each_slice(BATCH_LIMIT) do |batch|
            @sender.send_batch(batch, deadline: @shutdown_deadline)
          end
        end
        nil
      end
    end

    # Frozen wire format for timestamps (spec §4.4).
    def self.format_time(time)
      time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    private

    def guard(fallback = nil)
      yield
    rescue StandardError => e
      # Contract 1: the public API never raises after construction.
      @logger&.error("kilden: suppressed #{e.class}: #{e.message}")
      fallback
    end

    def open_for_events?
      if @closed
        @logger.warn("kilden: client is closed; event dropped")
        return false
      end
      true
    end

    def valid_id?(value, label)
      unless value.is_a?(String) && !value.empty?
        @logger.warn("kilden: #{label} must be a non-empty string; event dropped")
        return false
      end
      if value.bytesize > MAX_DISTINCT_ID_BYTES
        @logger.warn("kilden: #{label} exceeds #{MAX_DISTINCT_ID_BYTES} bytes; event dropped")
        return false
      end
      true
    end

    def build_event(distinct_id, event, properties, opts, reserved: false)
      return nil unless valid_id?(distinct_id, "distinct_id")

      unless event.is_a?(String) && !event.empty?
        @logger.warn("kilden: event must be a non-empty string; event dropped")
        return nil
      end
      if event.bytesize > MAX_EVENT_BYTES
        @logger.warn("kilden: event name exceeds #{MAX_EVENT_BYTES} bytes; event dropped")
        return nil
      end
      properties = {} if properties.nil?
      unless properties.is_a?(Hash)
        @logger.warn("kilden: properties must be a Hash; event dropped")
        return nil
      end
      if @debug && !reserved && (event.start_with?("$") || properties.keys.any? { |k| k.to_s.start_with?("$") })
        @logger.debug("kilden: the $ prefix is reserved for Kilden events/properties (sent anyway)")
      end

      begin
        JSON.generate(properties)
      rescue StandardError
        @logger.warn("kilden: properties are not JSON-serializable; event dropped")
        return nil
      end

      timestamp = event_timestamp(opts)
      return nil unless timestamp

      uuid = opts[:uuid] || opts["uuid"]
      if uuid && !UUID.canonical?(uuid)
        @logger.warn("kilden: uuid option is not a canonical UUID; event dropped")
        return nil
      end

      {
        "uuid" => uuid || UUID.v7,
        "event" => event,
        "distinct_id" => distinct_id,
        "properties" => properties,
        "timestamp" => timestamp
      }
    end

    def event_timestamp(opts)
      raw = opts[:timestamp] || opts["timestamp"]
      return Client.format_time(Time.now) if raw.nil?

      time = case raw
             when Time then raw
             when String then Time.iso8601(raw)
             else raw.respond_to?(:to_time) ? raw.to_time : nil
             end
      return Client.format_time(time) if time

      @logger.warn("kilden: timestamp option is not a time; event dropped")
      nil
    rescue ArgumentError
      @logger.warn("kilden: timestamp option is not a valid ISO 8601 time; event dropped")
      nil
    end

    def enqueue(payload)
      check_fork
      unless @queue.push(payload)
        @logger.warn("kilden: queue full (#{payload["event"]} dropped)")
        return
      end
      ensure_worker
    end

    # Contract 9: preforking servers (puma, unicorn) fork after boot. The
    # child inherits the parent's queue and a dead worker thread; detect the
    # PID change, discard the inherited events (the parent owns them —
    # resending duplicates) and start a fresh worker.
    def check_fork
      return if @pid == Process.pid

      @lifecycle.synchronize do
        next if @pid == Process.pid

        discarded = @queue.reset!
        @flag_cache.clear
        @worker = nil
        @closed = false
        @shutdown_deadline = nil
        @pid = Process.pid
        @logger.info("kilden: fork detected (pid #{@pid}); discarded #{discarded} inherited events and restarted the worker")
      end
    end

    def ensure_worker
      return if @worker&.alive?

      @lifecycle.synchronize do
        next if @worker&.alive?

        @worker = Thread.new do
          loop do
            batch = @queue.wait_batch(@flush_interval, max: BATCH_LIMIT)
            @sender.send_batch(batch, deadline: @shutdown_deadline) unless batch.empty?
            break if @queue.closed? && @queue.size.zero?
          end
        end
        @worker.name = "kilden-worker"
      end
    end

    def fetch_flag(flag_key, distinct_id, person_properties)
      return [:miss, nil] unless @enabled

      unless flag_key.is_a?(String) && !flag_key.empty?
        @logger.warn("kilden: flag_key must be a non-empty string")
        return [:miss, nil]
      end
      return [:miss, nil] unless valid_id?(distinct_id, "distinct_id")

      check_fork

      # person_properties make the evaluation non-reusable: bypass the cache
      # entirely (no read, no write) per spec §8.2.
      if person_properties.nil? && (cached = @flag_cache.get(distinct_id))
        return cached.key?(flag_key) ? [:ok, cached[flag_key]] : [:miss, nil]
      end

      flags = @decide.flags_for(distinct_id, person_properties)
      return [:miss, nil] unless flags

      @flag_cache.set(distinct_id, flags) if person_properties.nil?
      flags.key?(flag_key) ? [:ok, flags[flag_key]] : [:miss, nil]
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  # One-attempt /decide lookups (spec §8.2: a flag answer that arrives after
  # a retry budget is useless — return the default instead).
  # @api private
  class Decide
    def initialize(write_key:, host:, timeout:, transport:, logger:)
      @write_key = write_key
      @url = "#{host.chomp("/")}/decide"
      @transport = transport || Transport::NetHttp.new(timeout: timeout)
      @logger = logger
    end

    def flags_for(distinct_id, person_properties)
      request = { "write_key" => @write_key, "distinct_id" => distinct_id }
      request["person_properties"] = person_properties unless person_properties.nil?

      response = @transport.post(@url, JSON.generate(request),
                                 "Content-Type" => "application/json",
                                 "User-Agent" => "kilden-ruby/#{VERSION}")
      unless response.status == 200
        @logger.warn("kilden: /decide failed (#{response.network_error? ? response.error&.class : "HTTP #{response.status}"}); using defaults")
        return nil
      end

      flags = JSON.parse(response.body)["flags"]
      flags.is_a?(Hash) ? flags : nil
    rescue JSON::ParserError
      @logger.warn("kilden: /decide returned a malformed body; using defaults")
      nil
    end
  end
end
