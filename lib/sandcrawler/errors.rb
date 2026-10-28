# frozen_string_literal: true

module Sandcrawler
  class Error < StandardError; end
  class UsageError < Error; end
  class SafetyError < Error; end
  class DeviceNotFoundError < Error; end
  class IntegrityError < Error; end
  class OutOfRangeError < Error; end
  class FormatError < Error; end
end
