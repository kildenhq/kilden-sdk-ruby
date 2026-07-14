# frozen_string_literal: true

module Kilden
  # Bounded in-memory queue (spec contract 7): at capacity the NEW event is
  # dropped, never the old ones, and the drop is counted. Wakes the worker
  # when flush_at is reached.
  # @api private
  class EventQueue
    attr_reader :dropped_count

    def initialize(max_size:, flush_at:)
      @max_size = max_size
      @flush_at = flush_at
      @items = []
      @dropped_count = 0
      @mutex = Mutex.new
      @signal = ConditionVariable.new
      @closed = false
    end

    # Returns false when the event was dropped because the queue is full.
    def push(event)
      @mutex.synchronize do
        if @items.size >= @max_size
          @dropped_count += 1
          return false
        end
        @items << event
        @signal.signal if @items.size >= @flush_at
        true
      end
    end

    # Blocks until flush_at is reached, `interval` elapses, or close; then
    # pops up to `max` events. Returns [] on a quiet interval tick.
    def wait_batch(interval, max: 1000)
      @mutex.synchronize do
        @signal.wait(@mutex, interval) if @items.size < @flush_at && !@closed
        @items.shift(max)
      end
    end

    # Everything queued at the moment of the call (for flush/shutdown).
    def drain
      @mutex.synchronize { @items.slice!(0, @items.size) }
    end

    def size
      @mutex.synchronize { @items.size }
    end

    def empty?
      size.zero?
    end

    def close
      @mutex.synchronize do
        @closed = true
        @signal.broadcast
      end
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    # Fork recovery (contract 9): the child discards the inherited queue —
    # those events belong to the parent; sending them twice would duplicate.
    def reset!
      @mutex.synchronize do
        discarded = @items.size
        @items.clear
        @closed = false
        discarded
      end
    end
  end
end
