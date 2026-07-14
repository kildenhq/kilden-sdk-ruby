require_relative "test_helper"

class CanonicalJSONTest < Minitest::Test
  def generate(value)
    Kilden::CanonicalJSON.generate(value)
  end

  def test_sorts_keys_at_every_level
    assert_equal '{"a":{"x":1,"y":2},"b":3}',
                 generate({ "b" => 3, "a" => { "y" => 2, "x" => 1 } })
  end

  def test_sorts_by_byte_order
    assert_equal '{"01num":"n","Mid":"m","alpha":"a","zeta":"z"}',
                 generate({ "zeta" => "z", "alpha" => "a", "Mid" => "m", "01num" => "n" })
  end

  def test_symbol_keys_serialize_as_strings
    assert_equal '{"plan":"pro"}', generate({ plan: "pro" })
  end

  def test_utf8_is_preserved_unescaped
    assert_equal '{"emoji":"🦄","name":"José Piñera"}',
                 generate({ "name" => "José Piñera", "emoji" => "🦄" })
  end

  def test_html_unsafe_ascii_is_escaped_like_go
    assert_equal '{"company":"Smith \\u0026 Sons \\u003cltd\\u003e"}',
                 generate({ "company" => "Smith & Sons <ltd>" })
  end

  def test_scalars
    assert_equal '{"a":0,"b":99.9,"c":true,"d":false,"e":null,"f":[1,"x",null]}',
                 generate({ "a" => 0, "b" => 99.9, "c" => true, "d" => false, "e" => nil, "f" => [1, "x", nil] })
  end
end
