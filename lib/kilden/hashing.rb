require "digest"

module Kilden
  # The frozen rollout hashing (spec §8.3). v1 never evaluates flags locally
  # — /decide does — but the algorithm is pinned now, tested against the
  # platform-generated vectors, so local evaluation can arrive later without
  # an API change or a bucketing flicker.
  # @api private
  module Hashing
    TWO_POW_64 = 2.0**64

    module_function

    def bucket(flag_key, distinct_id)
      fraction("#{flag_key}:#{distinct_id}") * 100
    end

    def variant_for(flag_key, distinct_id, variants)
      point = fraction("#{flag_key}:#{distinct_id}:variant") * 100
      cumulative = 0.0
      variants.each do |variant|
        cumulative += variant.fetch("rollout_percentage")
        return variant.fetch("key") if point < cumulative
      end
      true
    end

    def fraction(input)
      Digest::SHA256.digest(input)[0, 8].unpack1("Q>") / TWO_POW_64
    end
  end
end
