# frozen_string_literal: true

require "optparse"
require "json"
require_relative "cli/offline"
require_relative "cli/devices"

module Sandcrawler
  class CLI
    include Offline
    include Devices

    COMMANDS = %w[doctor dump scan ls extract copy serial auto].freeze

    def initialize(stdout: $stdout, stderr: $stderr, stdin: $stdin)
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
    end

    def run(arguments)
      args = arguments.dup
      return @stdout.puts(VERSION) || 0 if args == ["--version"]
      return @stdout.puts(help) || 0 if args.empty? || %w[-h --help].include?(args.first)

      command = args.shift
      raise UsageError, "Unknown command: #{command}" unless COMMANDS.include?(command)

      @options = { passes: 2, codepage: "IBM437" }
      parser = option_parser(command)
      parser.parse!(args)
      return @stdout.puts(parser) || 0 if @options[:help]

      validate_arguments(command, args)
      @log = Log.new(io: @stderr, verbose: @options[:verbose], quiet: @options[:quiet])
      send("run_#{command}", args)
    rescue UsageError, OptionParser::ParseError => e
      @stderr.puts("#{Log.escape(e.message)}\nUse sandcrawler --help for usage.")
      2
    rescue DeviceNotFoundError => e
      @stderr.puts(Log.escape(e.message))
      3
    rescue IntegrityError => e
      @stderr.puts(Log.escape(e.message))
      5
    rescue Error, SystemCallError, IOError => e
      @stderr.puts(Log.escape(e.message))
      1
    end

    private

    def help
      <<~TEXT
        sandcrawler #{VERSION} — read-only R2P2 file recovery
        Usage: sandcrawler COMMAND [IMAGE|MOUNTPOINT] [options]
          doctor                 Check environment and optional acquisition tools
          dump -o DIR            Preserve BOOTSEL flash with repeated reads
          scan IMAGE             List all FAT volume candidates
          ls IMAGE               List files (--long, --deleted)
          extract IMAGE -o DIR   Recover files (--deleted, --orphans, --carve)
          copy MOUNTPOINT -o DIR Copy a mounted volume without following symlinks
          serial -o DIR          Transfer files from CDC0 (--port PORT)
          auto -o DIR            Choose a route interactively and recover
        Use COMMAND --help for options. Dump before using flash_nuke.uf2.
      TEXT
    end

    def option_parser(command)
      OptionParser.new do |parser|
        parser.banner = "Usage: sandcrawler #{command} [IMAGE|MOUNTPOINT] [options]"
        parser.on("-o", "--output DIR", "Output directory") { |v| @options[:out] = v }
        parser.on("--offset N", "Volume byte offset (decimal or 0xHEX)") { |v| @options[:offset] = number(v) }
        parser.on("--geometry VALUES", "bps,spc,rsvd,fats,fatsz,root[,total,offset,root_cluster]") do |v|
          @options[:geometry] = geometry(v)
        end
        parser.on("--reference-image FILE") { |v| @options[:reference] = v }
        parser.on("--fat N", %w[1 2]) { |v| @options[:fat] = v.to_i }
        parser.on("--codepage NAME") do |v|
          @options[:codepage] = Encoding.find(v).name
        rescue ArgumentError
          raise UsageError, "Unknown codepage: #{v}"
        end
        parser.on("--passes N", Integer) { |v| @options[:passes] = v }
        parser.on("--picotool PATH") { |v| @options[:picotool] = v }
        parser.on("--port PORT") { |v| @options[:port] = v }
        parser.on("--root PATH", "Serial source directory (default /)") { |v| @options[:root] = v }
        %i[deleted orphans carve long json verbose quiet force].each do |option|
          parser.on("--#{option}") { @options[option] = true }
        end
        parser.on("-h", "--help") { @options[:help] = true }
      end
    end

    def validate_arguments(command, args)
      count = %w[scan ls extract copy].include?(command) ? 1 : 0
      raise UsageError, "#{command} expects #{count} input path(s)" unless args.size == count
      if %w[dump extract copy serial auto].include?(command) && !@options[:out]
        raise UsageError, "#{command} requires -o DIR"
      end
      raise UsageError, "--passes must be at least 2" if @options[:passes] < 2
      return unless @options[:geometry] && @options[:reference]

      raise UsageError, "Choose --geometry or --reference-image"
    end

    def number(value)
      result = Integer(value, value.start_with?("0x", "0X") ? 16 : 10)
      raise ArgumentError if result.negative?

      result
    rescue ArgumentError
      raise UsageError, "Invalid nonnegative integer: #{value}"
    end

    def geometry(value)
      allowed = %w[bps spc rsvd fats fatsz root total totsec offset root_cluster media]
      fields = value.split(",", -1).each_with_object({}) do |field, result|
        key, number = field.split("=", 2)
        raise UsageError, "Invalid geometry field: #{field}" unless allowed.include?(key) && number
        raise UsageError, "Duplicate geometry field: #{key}" if result.key?(key.to_sym)

        result[key.to_sym] = self.number(number)
      end
      missing = %i[bps spc rsvd fats fatsz root] - fields.keys
      raise UsageError, "Missing geometry fields: #{missing.join(', ')}" unless missing.empty?
      raise UsageError, "Specify either total or totsec, not both" if fields.key?(:total) && fields.key?(:totsec)

      fields
    end

    def emit(value)
      if @options[:json]
        @stdout.puts(JSON.pretty_generate(Manifest.json_safe(value)))
      elsif !@options[:quiet]
        yield if block_given?
      end
    end

    def result_code(manifest)
      loss_codes = %w[DIRECTORY_DAMAGED DIRECTORY_ERROR DIRECTORY_LOOP DIRECTORY_WRITE_ERROR COPY_FAILED LIST_FAILED
                      FILE_ERROR UF2_INCOMPLETE FAT_ERASED_ENTRY CHAIN_ERROR CHAIN_FREE CHAIN_TOO_LONG CROSS_LINK
                      DUPLICATE_ENTRY]
      partial = manifest[:files].any? { |file| file[:status] != "ok" }
      partial ||= manifest[:warnings].any? { |warning| loss_codes.include?(warning[:code]) }
      partial ? 4 : 0
    end
  end
end
