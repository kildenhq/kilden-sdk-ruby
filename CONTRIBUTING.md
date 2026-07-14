# Contributing

Behavior of this SDK is governed by
[kilden-sdk-spec](https://github.com/freshworkstudio/kilden-sdk-spec) — the
spec, its frozen test vectors and its mock capture server are the authority.
**A PR that changes observable behavior without a matching spec change is
rejected**; open the spec PR first. Divergence between this SDK and the spec
is always a bug here (or a spec bug worth reporting there), never a feature.

## Running the tests

```sh
bundle install
bundle exec rake test          # unit — no network
bundle exec rake integration   # needs Go + a kilden-sdk-spec checkout
bundle exec rubocop
```

Integration tests boot the spec repo's mock server themselves; point
`KILDEN_SPEC_DIR` at your checkout (default: `../kilden-sdk-spec`). The
fork-safety test boots a real preforked puma — if you touch the queue, the
worker or PID handling, that test is the one that must stay green.

## Ground rules

- Zero runtime dependencies. That is a feature, not an accident.
- The public API never raises after construction (spec contract 1).
- Never mutate caller data (contract 3).

## Questions

[Discussions](https://github.com/freshworkstudio/kilden-sdk-ruby/discussions)
— answers there stay searchable.
