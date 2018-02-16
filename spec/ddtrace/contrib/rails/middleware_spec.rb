require 'ddtrace/contrib/rails/rails_helper'

RSpec.describe 'Rails request' do
  include Rack::Test::Methods
  include_context 'Rails test application'

  let(:routes) { { '/' => 'test#index' } }
  let(:controllers) { [controller] }

  let(:controller) do
    stub_const('TestController', Class.new(ActionController::Base) do
      def index
        head :ok
      end
    end)
  end

  let(:tracer) { ::Datadog::Tracer.new(writer: FauxWriter.new) }

  def all_spans
    tracer.writer.spans(:keep)
  end

  before(:each) do
    Datadog.configure do |c|
      c.use :rack, tracer: tracer
      c.use :rails, tracer: tracer
    end
  end

  context 'with middleware' do
    before(:each) { get '/' }

    let(:rails_middleware) { [middleware] }

    context 'that raises an exception' do
      let(:middleware) do
        stub_const('RaiseExceptionMiddleware', Class.new do
          def initialize(app)
            @app = app
          end

          def call(env)
            @app.call(env)
            raise NotImplementedError.new
          end
        end)
      end

      it do
        expect(last_response).to be_server_error
        expect(all_spans.length).to be >= 2
      end

      context 'rack span' do
        subject(:span) { all_spans.first }

        it do
          expect(span.name).to eq('rack.request')
          expect(span.span_type).to eq('http')
          expect(span.resource).to eq('TestController#index')
          expect(span.get_tag('http.url')).to eq('/')
          expect(span.get_tag('http.method')).to eq('GET')
          expect(span.get_tag('http.status_code')).to eq('500')
          expect(span.get_tag('error.type')).to eq('NotImplementedError')
          expect(span.get_tag('error.msg')).to eq('NotImplementedError')
          expect(span.status).to eq(Datadog::Ext::Errors::STATUS)
          expect(span.get_tag('error.stack')).to_not be nil
        end
      end
    end

    context 'that raises a known NotFound exception' do
      let(:middleware) do
        stub_const('RaiseNotFoundMiddleware', Class.new do
          def initialize(app)
            @app = app
          end

          def call(env)
            @app.call(env)
            raise ActionController::RoutingError.new('/missing_route')
          end
        end)
      end

      it do
        expect(last_response).to be_not_found
        expect(all_spans.length).to be >= 2
      end

      context 'rack span' do
        subject(:span) { all_spans.first }

        it do
          expect(span.name).to eq('rack.request')
          expect(span.span_type).to eq('http')
          expect(span.resource).to eq('TestController#index')
          expect(span.get_tag('http.url')).to eq('/')
          expect(span.get_tag('http.method')).to eq('GET')
          expect(span.get_tag('http.status_code')).to eq('404')

          if Rails.version >= '3.2'
            expect(span.get_tag('error.type')).to be nil
            expect(span.get_tag('error.msg')).to be nil
            expect(span.status).to_not eq(Datadog::Ext::Errors::STATUS)
            expect(span.get_tag('error.stack')).to be nil
          else
            # Rails 3.0 raises errors for 404 routing errors
            expect(span.get_tag('error.type')).to eq('ActionController::RoutingError')
            expect(span.get_tag('error.msg')).to eq('/missing_route')
            expect(span.status).to eq(Datadog::Ext::Errors::STATUS)
            expect(span.get_tag('error.stack')).to_not be nil
          end
        end
      end
    end

    context 'that raises a custom exception' do
      let(:error_class) do
        stub_const('CustomError', Class.new(StandardError) do
          def message
            'Custom error message!'
          end
        end)
      end

      let(:middleware) do
        # Run this to define the error class
        error_class

        stub_const('RaiseCustomErrorMiddleware', Class.new do
          def initialize(app)
            @app = app
          end

          def call(env)
            @app.call(env)
            raise CustomError.new
          end
        end)
      end

      it do
        expect(last_response).to be_server_error
        expect(all_spans.length).to be >= 2
      end

      context 'rack span' do
        subject(:span) { all_spans.first }

        it do
          expect(span.name).to eq('rack.request')
          expect(span.span_type).to eq('http')
          expect(span.resource).to eq('TestController#index')

          if Rails.version >= '3.2'
            expect(span.get_tag('http.url')).to eq('/')
          else
          end

          expect(span.get_tag('http.method')).to eq('GET')
          expect(span.get_tag('http.status_code')).to eq('500')
          expect(span.get_tag('error.type')).to eq('CustomError')
          expect(span.get_tag('error.msg')).to eq('Custom error message!')
          expect(span.status).to eq(Datadog::Ext::Errors::STATUS)
          expect(span.get_tag('error.stack')).to_not be nil
        end
      end

      if Rails.version >= '3.2'
        context 'that is flagged as a custom 404' do
          # TODO: Make a cleaner API for injecting into Rails application configuration
          let(:initialize_block) do
            super_block = super()
            Proc.new do
            self.instance_exec(&super_block)
              config.action_dispatch.rescue_responses.merge!(
                'CustomError' => :not_found
              )
            end
          end

          after(:each) do
            # Be sure to delete configuration after, so it doesn't carry over to other examples.
            # TODO: Clear this configuration automatically via rails_helper shared examples
            ActionDispatch::Railtie.config.action_dispatch.rescue_responses.delete('CustomError')
            ActionDispatch::ExceptionWrapper.class_variable_get(:@@rescue_responses).tap do |resps|
              resps.delete('CustomError')
            end
          end

          it do
            expect(last_response).to be_not_found
            expect(all_spans.length).to be >= 2
          end

          context 'rack span' do
            subject(:span) { all_spans.first }

            it do
              expect(span.name).to eq('rack.request')
              expect(span.span_type).to eq('http')
              expect(span.resource).to eq('TestController#index')
              expect(span.get_tag('http.url')).to eq('/')
              expect(span.get_tag('http.method')).to eq('GET')
              expect(span.get_tag('http.status_code')).to eq('404')
              expect(span.get_tag('error.type')).to be nil
              expect(span.get_tag('error.msg')).to be nil
              expect(span.status).to_not eq(Datadog::Ext::Errors::STATUS)
              expect(span.get_tag('error.stack')).to be nil
            end
          end
        end
      end
    end
  end
end
