require_relative "test_helper"

class FlagCacheTest < Minitest::Test
  def test_ttl_expiry
    now = [0.0]
    cache = Kilden::FlagCache.new(clock: -> { now[0] })
    cache.set("u1", { "f" => true })

    now[0] = 29.9
    assert_equal({ "f" => true }, cache.get("u1"))
    now[0] = 30.0
    assert_nil cache.get("u1")
  end

  def test_lru_eviction_keeps_recently_used
    cache = Kilden::FlagCache.new(clock: -> { 0.0 })
    1000.times { |i| cache.set("u#{i}", { "i" => i }) }

    cache.get("u0") # touch: u0 becomes most recently used
    cache.set("u1000", { "i" => 1000 })

    assert_equal({ "i" => 0 }, cache.get("u0"))
    assert_nil cache.get("u1") # the oldest untouched entry was evicted
  end
end
