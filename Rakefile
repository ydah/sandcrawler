# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rbconfig"

desc "Generate FAT fixtures with dosfstools and mtools (or use downloaded fixtures)"
task :fixtures do
  next if File.file?("test/fixtures/generated/complete")

  commands = %w[bash mkfs.fat mmd mcopy mdel]
  missing = commands.reject do |command|
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, command))
    end
  end
  if missing.empty?
    sh({ "RUBY" => RbConfig.ruby }, "bash", "script/build_fixtures.sh")
  elsif ENV["REQUIRE_FIXTURES"] == "1"
    abort "Missing fixture tools: #{missing.join(', ')}. Install dosfstools and mtools."
  else
    warn "External FAT fixtures unavailable (#{missing.join(', ')}); synthetic unit tests still run. " \
         "Install dosfstools/mtools and run rake fixtures for integration coverage."
  end
end

Rake::TestTask.new(test: :fixtures) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

task default: :test
