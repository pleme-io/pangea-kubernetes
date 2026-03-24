# frozen_string_literal: true

# Tests for TypedSynthesizerContext strict mode.
#
# Strict mode (strict: true) rejects untyped resource calls that hit
# method_missing instead of going through real provider modules.
# Non-strict mode (default) preserves backward compatibility.

require 'pangea-aws'

RSpec.describe TypedSynthesizerContext do
  include TypedContextHelpers

  describe 'strict mode' do
    let(:strict_ctx) { create_typed_aws_context(strict: true) }

    it 'allows typed resource calls through real provider methods' do
      # aws_vpc is defined by Pangea::Resources::AWS, so it should work
      expect {
        strict_ctx.aws_vpc(:test_vpc,
          cidr_block: '10.0.0.0/16',
          enable_dns_hostnames: true,
          enable_dns_support: true,
          tags: { Name: 'test' }
        )
      }.not_to raise_error
    end

    it 'raises NoMethodError for untyped aws_ resource calls' do
      # aws_fake_resource is not defined by any provider module,
      # so it falls through to method_missing and should be rejected
      expect {
        strict_ctx.aws_fake_resource(:test, { name: 'test' })
      }.to raise_error(NoMethodError, /Strict mode.*aws_fake_resource/)
    end

    it 'raises NoMethodError for untyped google_ resource calls' do
      expect {
        strict_ctx.google_fake_resource(:test, { name: 'test' })
      }.to raise_error(NoMethodError, /Strict mode.*google_fake_resource/)
    end

    it 'raises NoMethodError for untyped azurerm_ resource calls' do
      expect {
        strict_ctx.azurerm_fake_resource(:test, { name: 'test' })
      }.to raise_error(NoMethodError, /Strict mode.*azurerm_fake_resource/)
    end

    it 'raises NoMethodError for untyped hcloud_ resource calls' do
      expect {
        strict_ctx.hcloud_fake_resource(:test, { name: 'test' })
      }.to raise_error(NoMethodError, /Strict mode.*hcloud_fake_resource/)
    end

    it 'allows non-resource method calls (e.g., resource() stub)' do
      # The resource() method is defined on TypedSynthesizerContext itself,
      # so it should work even in strict mode
      expect {
        strict_ctx.resource(:aws_vpc, :test_vpc, { cidr_block: '10.0.0.0/16' })
      }.not_to raise_error
    end
  end

  describe 'non-strict mode (default)' do
    let(:ctx) { create_typed_aws_context }

    it 'allows typed resource calls' do
      expect {
        ctx.aws_vpc(:test_vpc,
          cidr_block: '10.0.0.0/16',
          enable_dns_hostnames: true,
          enable_dns_support: true,
          tags: { Name: 'test' }
        )
      }.not_to raise_error
    end

    it 'allows untyped resource calls (backward compat)' do
      expect {
        ctx.aws_fake_resource(:test, { name: 'test' })
      }.not_to raise_error
    end

    it 'records untyped resource calls' do
      ctx.aws_fake_resource(:test, { name: 'test' })
      expect(ctx.created_resources.length).to be >= 1
      expect(ctx.find_resource(:aws_fake_resource, :test)).not_to be_nil
    end
  end

  describe 'strict: false is the default' do
    it 'defaults to non-strict when no argument given' do
      ctx = TypedSynthesizerContext.new
      # Untyped calls should work by default
      expect {
        ctx.aws_fake_resource(:test, { name: 'test' })
      }.not_to raise_error
    end
  end
end
