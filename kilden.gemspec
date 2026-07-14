# frozen_string_literal: true

require_relative "lib/kilden/version"

Gem::Specification.new do |spec|
  spec.name = "kilden"
  spec.version = Kilden::VERSION
  spec.authors = ["Freshwork"]
  spec.email = ["hello@kilden.io"]

  spec.summary = "Kilden server-side SDK for Ruby"
  spec.description = "Server-side events, identity signing and feature flags for Kilden. " \
                     "Zero runtime dependencies, fork-safe under preforking servers."
  spec.homepage = "https://github.com/kildenhq/kilden-sdk-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://kilden.io/docs",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
end
