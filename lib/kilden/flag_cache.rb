module Kilden
  # TTL + LRU cache of /decide responses, keyed by distinct_id (spec §8.2:
  # TTL 30s, at most 1000 ids). Ruby's insertion-ordered Hash doubles as the
  # LRU list: delete + reinsert on hit, shift the oldest on overflow.
  # @api private
  class FlagCache
    TTL = 30
    MAX_IDS = 1000

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @entries = {}
      @mutex = Mutex.new
    end

    def get(distinct_id)
      @mutex.synchronize do
        entry = @entries.delete(distinct_id)
        return nil unless entry
        return nil if @clock.call >= entry[0]

        @entries[distinct_id] = entry
        entry[1]
      end
    end

    def set(distinct_id, flags)
      @mutex.synchronize do
        @entries.delete(distinct_id)
        @entries[distinct_id] = [@clock.call + TTL, flags]
        @entries.shift if @entries.size > MAX_IDS
      end
    end

    def clear
      @mutex.synchronize { @entries.clear }
    end
  end
end
