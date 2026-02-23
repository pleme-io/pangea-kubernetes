# frozen_string_literal: true

# Test helpers for kubernetes architecture synthesis validation.
# Provides a mock synthesizer that captures resource calls from backends
# without requiring actual provider gems.
module SynthesisTestHelpers
  # Create a mock synthesizer context that records resource calls
  def create_mock_context
    MockSynthesizerContext.new
  end

  # Validate that expected resources were created
  def expect_resource(context, resource_type, resource_name)
    resources = context.created_resources
    match = resources.find { |r| r[:type] == resource_type && r[:name] == resource_name }
    expect(match).not_to be_nil,
      "Expected resource #{resource_type}.#{resource_name} to be created. " \
      "Created resources: #{resources.map { |r| "#{r[:type]}.#{r[:name]}" }.join(', ')}"
    match
  end

  # Validate resource count for a type
  def expect_resource_count(context, resource_type, count)
    actual = context.created_resources.count { |r| r[:type] == resource_type }
    expect(actual).to eq(count),
      "Expected #{count} #{resource_type} resources, got #{actual}"
  end
end

# Mock synthesizer context that records all resource creation calls.
# Simulates provider gem resource functions without requiring them.
class MockSynthesizerContext
  attr_reader :created_resources

  def initialize
    @created_resources = []
  end

  # Catch all resource function calls (aws_eks_cluster, hcloud_server, etc.)
  def method_missing(method_name, *args, &block)
    resource_name = args[0]
    resource_attrs = args[1] || {}

    ref = MockResourceRef.new(method_name.to_s, resource_name, resource_attrs)
    @created_resources << { type: method_name.to_s, name: resource_name, attrs: resource_attrs, ref: ref }
    ref
  end

  def respond_to_missing?(_method_name, _include_private = false)
    true
  end

  # Find a created resource by type and name
  def find_resource(type, name)
    @created_resources.find { |r| r[:type] == type.to_s && r[:name] == name }
  end

  # Count resources of a given type
  def count_resources(type)
    @created_resources.count { |r| r[:type] == type.to_s }
  end
end

# Mock resource reference that provides terraform-style output accessors
class MockResourceRef
  attr_reader :type, :resource_name, :attributes

  def initialize(type, name, attributes = {})
    @type = type
    @resource_name = name
    @attributes = attributes
  end

  def id
    "${#{@type}.#{@resource_name}.id}"
  end

  def arn
    "${#{@type}.#{@resource_name}.arn}"
  end

  def name
    attributes[:name] || "${#{@type}.#{@resource_name}.name}"
  end

  def email
    "${#{@type}.#{@resource_name}.email}"
  end

  def ipv4_address
    "${#{@type}.#{@resource_name}.ipv4_address}"
  end

  def endpoint
    "${#{@type}.#{@resource_name}.endpoint}"
  end

  def to_h
    {
      type: @type,
      name: @resource_name,
      attributes: @attributes
    }
  end

  def method_missing(method_name, *_args, &_block)
    if @attributes.key?(method_name)
      @attributes[method_name]
    else
      "${#{@type}.#{@resource_name}.#{method_name}}"
    end
  end

  def respond_to_missing?(_method_name, _include_private = false)
    true
  end
end
