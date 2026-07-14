require_relative "test_helper"

# Frozen-vector runners (spec §9) that need no network: identity tokens must
# be byte-identical to the platform's Go generator; the rollout hashing must
# land every one of the 200 pinned buckets.
class IdentityVectorsTest < Minitest::Test
  DOC = JSON.parse(File.read(File.join(SPEC_DIR, "vectors", "identity.json")))

  DOC["vectors"].each do |vector|
    define_method("test_#{vector["name"]}") do
      signer = Kilden::IdentitySigner.new(vector["secret"], kid: vector["kid"])
      token = signer.send(:build, vector["sub"],
                          iat: vector["iat"], exp: vector["exp"], traits: vector["traits"])
      assert_equal vector["token"], token, "identity token diverges from the frozen vector"
    end
  end
end

class FlagHashingVectorsTest < Minitest::Test
  DOC = JSON.parse(File.read(File.join(SPEC_DIR, "vectors", "flag-hashing.json")))

  def test_rollout_buckets
    DOC["rollout"].each do |vector|
      bucket = Kilden::Hashing.bucket(vector["flag_key"], vector["distinct_id"])
      assert_equal vector["bucket_floor"], bucket.floor,
                   "bucket(#{vector["flag_key"].inspect}, #{vector["distinct_id"].inspect})"
    end
    assert_operator DOC["rollout"].size, :>=, 200
  end

  def test_variant_picks
    DOC["variants"].each do |vector|
      got = Kilden::Hashing.variant_for(vector["flag_key"], vector["distinct_id"], vector["variants"])
      assert_equal vector["expected"], got
    end
    assert_operator DOC["variants"].size, :>=, 12
  end
end
