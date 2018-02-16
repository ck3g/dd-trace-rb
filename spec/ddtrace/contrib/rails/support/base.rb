require 'rails/all'
require 'ddtrace'

if ENV['USE_SIDEKIQ']
  require 'sidekiq/testing'
  require 'ddtrace/contrib/sidekiq/tracer'
end

require 'set'
$configs = Set.new
$applications = Set.new
$middlewares = Set.new
$route_sets = Set.new

RSpec.shared_context 'Rails base application' do
  if Rails.version >= '5.0'
    require 'ddtrace/contrib/rails/support/rails5'
    include_context 'Rails 5 base application'
  elsif Rails.version >= '4.0'
    require 'ddtrace/contrib/rails/support/rails4'
    include_context 'Rails 4 base application'
  elsif Rails.version >= '3.0'
    require 'ddtrace/contrib/rails/support/rails3'
    include_context 'Rails 3 base application'
  else
    logger.error 'A Rails app for this version is not found!'
  end

  let(:initialize_block) do
    middleware = rails_middleware
    debug_mw = debug_middleware

    Proc.new do
      config.middleware.insert_before 0, debug_mw
      middleware.each { |m| config.middleware.use m }
    end
  end

  let(:before_test_initialize_block) do
    Proc.new do
      append_routes!
    end
  end

  let(:after_test_initialize_block) do
    Proc.new do
      models
    end
  end
end
