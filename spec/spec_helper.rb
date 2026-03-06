# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/vendor/'
  track_files 'lib/**/*.rb'
end

lib_path = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)

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

require 'pangea/testing'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

Pangea::Testing::SpecSetup.configure!
