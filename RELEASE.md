# Releasing

Releases are cut from `v*` tags; `release.yml` runs the suite, builds the
gem, publishes to RubyGems via **OIDC trusted publishing** (no API key
secret), and creates the GitHub prerelease with the `.gem` attached.

## One-time setup

Register the trusted publisher on rubygems.org (works before the first push,
as a *pending* publisher): profile → OIDC → Pending trusted publishers →

- RubyGem name: `kilden`
- Repository: `kildenhq/kilden-sdk-ruby`
- Workflow filename: `release.yml` · Environment: (leave empty)

## Cutting a release

1. Bump `Kilden::VERSION` in `lib/kilden/version.rb`
   (gem prerelease format: `0.1.0.alpha.3` ↔ git tag `v0.1.0-alpha.3`).
2. Update `CHANGELOG.md`.
3. `git tag v0.1.0-alpha.3 && git push origin v0.1.0-alpha.3`.

Manual fallback (needs an API key): `gem build kilden.gemspec && gem push
kilden-*.gem`.
