# Releasing

Releases are cut from a git tag; CI publishes to RubyGems.

1. Update `lib/kilden/version.rb` and `CHANGELOG.md`.
2. `bundle exec rake all && bundle exec rubocop && gem build kilden.gemspec`
3. Commit, tag and push:

   ```sh
   git tag v0.1.0-alpha.1
   git push origin main v0.1.0-alpha.1
   ```

The `release` workflow builds the gem and runs `gem push`, authenticating
with the `RUBYGEMS_API_KEY` repository secret.

## Until the secret exists

`RUBYGEMS_API_KEY` is not configured yet, so tags build but do not publish.
To publish manually:

```sh
gem build kilden.gemspec
GEM_HOST_API_KEY=<rubygems-api-key> gem push kilden-0.1.0.alpha.1.gem
```

The RubyGems version for a `vX.Y.Z-alpha.N` tag is `X.Y.Z.alpha.N` (RubyGems
prerelease versions use dots, git tags use the SemVer dash).
