# Release procedure

Publishing is a separate maintainer action. Implementation does not publish a gem or create release tags.

1. Review `docs/findings.md`; state hardware limitations in release notes.
2. Update `lib/sandcrawler/version.rb` and `CHANGELOG.md`.
3. Run full tests with generated fixtures, lint, and build:

   ```sh
   REQUIRE_FIXTURES=1 bundle exec rake test
   bundle exec rubocop
   gem build sandcrawler.gemspec
   ```

4. Install the artifact in a temporary gem home and smoke-test the installed command (substitute the release version):

   ```sh
   gem install --install-dir ./tmp/release-gems ./sandcrawler-0.1.0.gem --no-document
   GEM_HOME=./tmp/release-gems ./tmp/release-gems/bin/sandcrawler --version
   GEM_HOME=./tmp/release-gems ./tmp/release-gems/bin/sandcrawler doctor
   ```

   A build machine may lack devices or optional tools. Record `doctor`'s result without claiming hardware validation.

5. Verify CI and package contents: executable, every runtime Ruby file, README, license, changelog, and docs. Generated images and tests must be excluded.
6. Verify ownership/availability of the `sandcrawler` name on RubyGems, enable MFA, and review the commit/version. After publication is explicitly approved, `bundle exec rake release` creates/pushes the tag and publishes the gem.

The gemspec requires MFA and allows pushes only to `https://rubygems.org`.
