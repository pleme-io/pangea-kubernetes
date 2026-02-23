# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/vendor/'
  track_files 'lib/**/*.rb'
end

lib_path = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)

require 'rspec'

begin
  require 'dry-types'
  require 'dry-struct'
  require 'terraform-synthesizer'
  require 'json'
rescue LoadError => e
  puts "Warning: Could not load dependency: #{e.message}"
end

begin
  require 'pangea-kubernetes'

  # Load all backends for testing (normally lazy-loaded)
  # Managed backends
  require 'pangea/kubernetes/backends/aws_eks'
  require 'pangea/kubernetes/backends/gcp_gke'
  require 'pangea/kubernetes/backends/azure_aks'
  # NixOS backends
  require 'pangea/kubernetes/backends/aws_nixos'
  require 'pangea/kubernetes/backends/gcp_nixos'
  require 'pangea/kubernetes/backends/azure_nixos'
  require 'pangea/kubernetes/backends/hcloud_k3s'
rescue LoadError => e
  puts "Warning: Could not load pangea-kubernetes: #{e.message}"
end

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.include SynthesisTestHelpers if defined?(SynthesisTestHelpers)
  config.before(:suite) { ENV['PANGEA_ENV'] = 'test' }
  config.formatter = :progress
  config.color = true
  config.filter_run_when_matching :focus
  config.run_all_when_everything_filtered = true
  config.order = :random
  Kernel.srand config.seed
  config.warnings = false
end
