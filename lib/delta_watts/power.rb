# frozen_string_literal: true

require "json"
require "fileutils"

module DeltaWatts
  class PowerSampler
    ROOT = File.expand_path("../..", __dir__)
    SRC = File.join(ROOT, "ext", "power_sampler.c")
    BIN = File.join(ROOT, "libexec", "power_sampler")

    def self.start
      new
    rescue StandardError
      nil
    end

    def initialize
      build!
      @io = IO.popen([BIN], "r+")
      @io.sync = true
    end

    def sample
      return nil unless @io && !@io.closed?

      @io.puts
      line = @io.gets
      return nil if line.nil? || line.empty?

      data = JSON.parse(line)
      return nil unless data["ok"]

      watts = [data["sys"].to_f, data["all"].to_f].max
      return nil unless watts.finite? && watts.between?(0.0, 400.0)

      watts
    rescue StandardError
      nil
    end

    def stop
      return unless @io

      @io.close
    rescue StandardError
      nil
    ensure
      @io = nil
    end

    private

    def build!
      FileUtils.mkdir_p(File.dirname(BIN))
      return if File.executable?(BIN) && File.mtime(BIN) >= File.mtime(SRC)

      ok = system(
        "cc", "-O2", "-o", BIN, SRC,
        "-framework", "IOKit",
        "-framework", "CoreFoundation",
        "-lIOReport",
        out: File::NULL,
        err: File::NULL
      )
      raise "failed to build #{BIN}" unless ok && File.executable?(BIN)
    end
  end
end
