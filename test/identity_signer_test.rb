require_relative "test_helper"

class IdentitySignerTest < Minitest::Test
  def signer
    Kilden::IdentitySigner.new("test-secret", kid: "k1")
  end

  def test_requires_secret_and_kid
    assert_raises(Kilden::ConfigurationError) { Kilden::IdentitySigner.new("", kid: "k1") }
    assert_raises(Kilden::ConfigurationError) { Kilden::IdentitySigner.new(nil, kid: "k1") }
    assert_raises(Kilden::ConfigurationError) { Kilden::IdentitySigner.new("secret", kid: "") }
  end

  def test_rejects_bad_subs_and_ttls
    assert_raises(ArgumentError) { signer.sign("") }
    assert_raises(ArgumentError) { signer.sign(nil) }
    assert_raises(ArgumentError) { signer.sign("user_1", ttl: 0) }
    assert_raises(ArgumentError) { signer.sign("user_1", ttl: -5) }
    assert_raises(ArgumentError) { signer.sign("user_1", ttl: 604_801) }
  end

  def test_signs_with_default_ttl
    token = signer.sign("user_42", traits: { "plan" => "pro" })
    header, payload, signature = token.split(".")

    decoded_header = JSON.parse(pad_decode(header))
    assert_equal({ "alg" => "HS256", "kid" => "k1", "typ" => "JWT" }, decoded_header)

    claims = JSON.parse(pad_decode(payload))
    assert_equal "user_42", claims["sub"]
    assert_equal({ "plan" => "pro" }, claims["traits"])
    assert_equal claims["iat"] + 3600, claims["exp"]

    refute_empty signature
    refute_includes token, "=" # base64url without padding
  end

  def test_empty_traits_are_omitted
    token = signer.sign("user_42", traits: {})
    claims = JSON.parse(pad_decode(token.split(".")[1]))
    refute claims.key?("traits")
  end

  private

  def pad_decode(segment)
    padded = segment + "=" * ((4 - segment.length % 4) % 4)
    padded.tr("-_", "+/").unpack1("m")
  end
end
