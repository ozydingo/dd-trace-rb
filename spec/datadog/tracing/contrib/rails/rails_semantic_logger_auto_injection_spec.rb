require 'datadog/tracing/contrib/rails/rails_helper'

RSpec.describe 'Rails Log Auto Injection' do
  include Rack::Test::Methods
  include_context 'Rails test application'

  let(:routes) do
    { '/logging' => 'logging_test#index' }
  end

  let(:controllers) do
    [logging_test_controller]
  end

  let(:logging_test_controller) do
    stub_const(
      'LoggingTestController',
      Class.new(ActionController::Base) do
        def index
          logger.info 'MY VOICE SHALL BE HEARD!'
          render plain: 'OK'
        end
      end
    )
  end

  # defined in rails support apps
  let(:logs) { log_output.string }
  let(:log_entries) { logs.split("\n")}

  before do
    Datadog.configuration.tracing[:rails].reset_options!
    Datadog.configure do |c|
      c.tracing.instrument :rails
      c.tracing.log_injection = log_injection
    end

    allow(ENV).to receive(:[]).and_call_original
  end

  after do
    SemanticLogger.close

    Datadog.configuration.tracing[:rails].reset_options!
    Datadog.configuration.tracing[:semantic_logger].reset_options!
  end

  context 'with log injection enabled', if: Rails.version >= '4.0' do
    let(:log_injection) { true }

    context 'with Semantic Logger' do
      # for logsog_injection testing
      require 'rails_semantic_logger'

      subject(:response) { get '/logging' }

      before do
        allow(ENV).to receive(:[]).with('USE_SEMANTIC_LOGGER').and_return(true)
      end

      context 'with semantic logger enabled' do
        context 'with semantic logger setup and no log_tags' do
          it 'injects trace_id into logs' do
            is_expected.to be_ok
            # force flush
            SemanticLogger.flush

            expect(logs).to_not be_empty

            expect(log_entries).to have(6).items

            log_entries.each do |l|
              expect(l).to include(trace.id.to_s)
              expect(l).to include('ddsource: ruby')
            end
          end
        end

        context 'with semantic logger setup and existing log_tags' do
          before do
            allow(ENV).to receive(:[]).with('LOG_TAGS').and_return({ some_tag: 'some_value' })
          end

          it 'injects trace correlation context into logs and preserve existing log tags' do
            is_expected.to be_ok
            # force flush
            SemanticLogger.flush

            expect(logs).to_not be_empty

            expect(log_entries).to have(6).items

            log_entries.each do |l|
              expect(l).to include(trace.id.to_s)
              expect(l).to include('ddsource: ruby')
              expect(l).to include('some_tag')
              expect(l).to include('some_value')
            end
          end
        end
      end
    end
  end

  context 'with log injection disabled', if: Rails.version >= '4.0' do
    let(:log_injection) { false }

    before do
      Datadog.configuration.tracing[:semantic_logger].enabled = false
    end

    context 'with Semantic Logger' do
      # for logsog_injection testing
      require 'rails_semantic_logger'

      subject(:response) { get '/logging' }

      before do
        allow(ENV).to receive(:[]).with('USE_SEMANTIC_LOGGER').and_return(true)
      end

      context 'with semantic logger enabled' do
        context 'with semantic logger setup and no log_tags' do
          it 'does not inject trace_id into logs' do
            is_expected.to be_ok
            # force flush
            SemanticLogger.flush

            expect(logs).to_not be_empty

            expect(log_entries).to have(6).items

            log_entries.each do |l|
              expect(l).to_not be_empty

              expect(l).to_not include(trace.id.to_s)
              expect(l).to_not include('ddsource: ruby')
            end
          end
        end

        context 'with semantic logger setup and existing log_tags' do
          before do
            allow(ENV).to receive(:[]).with('LOG_TAGS').and_return({ some_tag: 'some_value' })
          end

          it 'does not inject trace correlation context and preserve existing log tags' do
            is_expected.to be_ok
            # force flush
            SemanticLogger.flush

            expect(logs).to_not be_empty

            expect(log_entries).to have(6).items

            log_entries.each do |l|
              expect(l).to_not be_empty

              expect(l).to_not include(trace.id.to_s)
              expect(l).to_not include('ddsource: ruby')
              expect(l).to include('some_tag')
              expect(l).to include('some_value')
            end
          end
        end
      end
    end
  end
end
