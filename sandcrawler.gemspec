# frozen_string_literal: true

require_relative "lib/sandcrawler/version"

Gem::Specification.new do |spec|
  spec.name = "sandcrawler"
  spec.version = Sandcrawler::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Salvage files from a Raspberry Pi Pico running R2P2"
  spec.description = "Read-only flash acquisition and offline FAT12/16/32 recovery, " \
                     "including deleted files and text carving."
  spec.homepage = "https://github.com/ydah/sandcrawler"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "exe/*", "docs/**/*.md", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  end
  spec.bindir = "exe"
  spec.executables = ["sandcrawler"]
  spec.require_paths = ["lib"]
end
