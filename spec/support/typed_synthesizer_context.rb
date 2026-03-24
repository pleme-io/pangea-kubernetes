# frozen_string_literal: true

# TypedSynthesizerContext — a test context that runs REAL type validation.
#
# Unlike MockSynthesizerContext (which uses method_missing to accept any
# resource call without validation), this context extends with the real
# provider module (e.g., Pangea::Resources::AWS) so that resource methods
# like aws_iam_role() call Types::IamRoleAttributes.new(attributes) before
# delegating to resource().
#
# The key insight: provider resource methods (e.g., aws_iam_role) do:
#   1. Validate attributes via dry-struct (e.g., IamRoleAttributes.new(attrs))
#   2. Call resource(:aws_iam_role, name) { ... } to emit Terraform HCL
#   3. Return a ResourceReference
#
# Step 2 calls `resource()` which is normally provided by TerraformSynthesizer.
# This class provides a stub `resource()` that records the call without
# generating HCL, while still getting full type validation from step 1.
class TypedSynthesizerContext
  attr_reader :created_resources

  def initialize
    @created_resources = []
  end

  # Stub for terraform-synthesizer's resource() method.
  # Provider resource methods call this internally after type validation.
  # The block configures HCL attributes using DSL methods — we execute it
  # against a NullBlockReceiver that absorbs all method calls silently.
  def resource(type, name, attrs = nil, &block)
    NullBlockReceiver.new.instance_eval(&block) if block

    ref = MockResourceRef.new(type.to_s, name, attrs || {})
    @created_resources << { type: type.to_s, name: name, attrs: attrs, ref: ref }
    ref
  end

  # Find a created resource by type and name
  def find_resource(type, name)
    @created_resources.find { |r| r[:type] == type.to_s && r[:name] == name }
  end

  # Count resources of a given type
  def count_resources(type)
    @created_resources.count { |r| r[:type] == type.to_s }
  end

  # For methods that the provider module doesn't define (e.g., resources
  # that don't have a dedicated resource.rb yet), fall back to mock behavior
  # similar to MockSynthesizerContext.
  def method_missing(method_name, *args, &block)
    # If it looks like a resource call (has a symbol name as first arg),
    # record it as a mock resource
    if args.first.is_a?(Symbol) || args.first.is_a?(String)
      resource_name = args[0]
      resource_attrs = args[1] || {}

      ref = MockResourceRef.new(method_name.to_s, resource_name, resource_attrs)
      @created_resources << { type: method_name.to_s, name: resource_name, attrs: resource_attrs, ref: ref }
      ref
    else
      super
    end
  end

  def respond_to_missing?(_method_name, _include_private = false)
    true
  end
end

# Absorbs all method calls silently. Used to execute terraform-synthesizer
# DSL blocks without actually generating HCL. Supports nested blocks
# (e.g., health_check { ... }, tags { ... }).
class NullBlockReceiver
  def method_missing(_method_name, *_args, &block)
    if block
      NullBlockReceiver.new.instance_eval(&block)
    else
      nil
    end
  end

  def respond_to_missing?(_method_name, _include_private = false)
    true
  end
end

# Helper module for creating typed contexts in specs
module TypedContextHelpers
  # Create a typed context that validates AWS resource calls through
  # real pangea-aws type definitions.
  def create_typed_aws_context
    require 'pangea-aws'
    ctx = TypedSynthesizerContext.new
    ctx.extend(Pangea::Resources::AWS)
    ctx
  end

  # Create a typed context for GCP resources
  def create_typed_gcp_context
    require 'pangea-gcp'
    require 'pangea/resources/google'
    ctx = TypedSynthesizerContext.new
    ctx.extend(Pangea::Resources::Google)
    ctx
  end

  # Create a typed context for Azure resources
  def create_typed_azure_context
    require 'pangea-azure'
    require 'pangea/resources/azure'
    ctx = TypedSynthesizerContext.new
    ctx.extend(Pangea::Resources::Azure)
    ctx
  end

  # Create a typed context for Hetzner Cloud resources
  def create_typed_hcloud_context
    require 'pangea-hcloud'
    require 'pangea/resources/hcloud'
    ctx = TypedSynthesizerContext.new
    ctx.extend(Pangea::Resources::Hcloud)
    ctx
  end
end
