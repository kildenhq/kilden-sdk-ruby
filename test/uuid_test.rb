require_relative "test_helper"

class UUIDTest < Minitest::Test
  def test_v7_shape
    100.times do
      assert_match Kilden::UUID::V7, Kilden::UUID.v7
    end
  end

  def test_v7_embeds_the_timestamp
    ms = 1_752_500_000_000
    uuid = Kilden::UUID.v7(ms)
    assert_equal ms.to_s(16).rjust(12, "0"), uuid.delete("-")[0, 12]
  end

  def test_v7_unique
    uuids = Array.new(1000) { Kilden::UUID.v7 }
    assert_equal 1000, uuids.uniq.size
  end

  def test_canonical_accepts_any_rfc4122
    assert Kilden::UUID.canonical?("0197fa10-7a2b-4c3d-8e4f-5a6b7c8d9e0f")
    assert Kilden::UUID.canonical?("0197FA10-7A2B-7C3D-8E4F-5A6B7C8D9E0F")
    refute Kilden::UUID.canonical?("not-a-uuid")
    refute Kilden::UUID.canonical?("0197fa107a2b7c3d8e4f5a6b7c8d9e0f")
    refute Kilden::UUID.canonical?(nil)
  end
end
