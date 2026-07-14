# frozen_string_literal: true

require_relative "test_helper"

class EventQueueTest < Minitest::Test
  def test_bounded_drops_the_new_event
    queue = Kilden::EventQueue.new(max_size: 2, flush_at: 100)

    assert queue.push(1)
    assert queue.push(2)
    refute queue.push(3)
    assert_equal 1, queue.dropped_count
    assert_equal [1, 2], queue.drain
  end

  def test_wait_batch_wakes_on_flush_at
    queue = Kilden::EventQueue.new(max_size: 100, flush_at: 2)
    waiter = Thread.new { queue.wait_batch(5, max: 10) }
    sleep 0.05
    queue.push(1)
    queue.push(2) # reaches flush_at → signals

    assert_equal [1, 2], waiter.value
  end

  def test_reset_discards_inherited_events
    queue = Kilden::EventQueue.new(max_size: 100, flush_at: 100)
    3.times { |i| queue.push(i) }

    assert_equal 3, queue.reset!
    assert_equal 0, queue.size
  end
end

class EventQueueEmptyTest < Minitest::Test
  def test_empty_reflects_queue_state
    q = Kilden::EventQueue.new(max_size: 10, flush_at: 5)

    assert_predicate q, :empty?
    q.push({ "event" => "e" })

    refute_predicate q, :empty?
    q.drain

    assert_predicate q, :empty?
  end
end
