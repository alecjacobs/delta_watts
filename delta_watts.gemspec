# frozen_string_literal: true

require_relative "lib/delta_watts/version"

Gem::Specification.new do |spec|
  spec.name = "delta_watts"
  spec.version = DeltaWatts::VERSION
  spec.authors = ["Buck"]
  spec.summary = "A tasteful TUI for Mac laptop power usage"
  spec.files = Dir.chdir(__dir__) { Dir.glob("{bin,lib,ext}/**/*", File::FNM_DOTMATCH) }
  spec.executables = ["delta_watts"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0"
end
