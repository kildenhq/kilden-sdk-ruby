# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0.alpha.1] - 2026-07-14

### Added

- `Kilden::Client`: `track`, `identify`, `alias`, `flush`, `close` with a
  bounded in-memory queue, background worker, gzip, and retries with
  exponential backoff honoring `Retry-After`.
- Fork safety under preforking servers (puma/unicorn), tested against a real
  `puma -w 2 --preload` in CI.
- `Kilden::IdentitySigner`: hand-rolled HS256 identity tokens, byte-exact
  against the platform's vectors.
- Feature flags: `enabled?` / `feature_flag` over `/decide` with a 30s
  TTL + LRU cache and `person_properties` / `default:` options.
- Frozen rollout hashing (spec §8.3), vector-tested for future local eval.
- Vector runners for the three kilden-sdk-spec vector files, wired into CI
  against the spec's mock capture server.

[Unreleased]: https://github.com/freshworkstudio/kilden-sdk-ruby/compare/v0.1.0-alpha.1...HEAD
[0.1.0.alpha.1]: https://github.com/freshworkstudio/kilden-sdk-ruby/releases/tag/v0.1.0-alpha.1
