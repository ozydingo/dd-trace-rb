require 'datadog/tracing/sampling/span/matcher'
require 'datadog/tracing/sampling/span/rule'

RSpec.describe Datadog::Tracing::Sampling::Span::Rule do
  subject(:rule) { described_class.new(matcher, sampling_rate, rate_limit) }
  let(:matcher) { instance_double(Datadog::Tracing::Sampling::Span::Matcher) }
  let(:sampling_rate) { 0.0 }
  let(:rate_limit) { 0 }

  let(:span_op) { Datadog::Tracing::SpanOperation.new(span_name, service: span_service) }
  let(:span_name) { 'operation.name' }
  let(:span_service) { '' }

  describe '#sample!' do
    subject(:sample!) { rule.sample!(span_op) }

    shared_examples 'does not modify span' do
      it { expect { sample! }.to_not(change { span_op.send(:build_span).to_hash }) }
    end

    context 'when matching' do
      before do
        expect(matcher).to receive(:match?).with(span_op).and_return(true)
      end

      context 'not sampled' do
        let(:sampling_rate) { 0.0 }

        it 'returns false' do
          is_expected.to eq(false)
        end

        it_behaves_like 'does not modify span'
      end

      context 'sampled' do
        let(:sampling_rate) { 1.0 }

        context 'rate limited' do
          let(:rate_limit) { 0 }

          it 'returns false' do
            is_expected.to eq(false)
          end

          it_behaves_like 'does not modify span'
        end

        context 'not rate limited' do
          let(:rate_limit) { 10 }

          it 'returns true' do
            is_expected.to eq(true)
          end

          it 'sets mechanism, rule rate and rate limit metrics' do
            sample!

            expect(span_op.get_metric('_dd.span_sampling.mechanism')).to eq(8)
            expect(span_op.get_metric('_dd.span_sampling.rule_rate')).to eq(1.0)
            expect(span_op.get_metric('_dd.span_sampling.limit_rate')).to eq(1.0)
          end
        end
      end
    end

    context 'when not matching' do
      before do
        expect(matcher).to receive(:match?).with(span_op).and_return(false)
      end

      it 'returns nil' do
        is_expected.to be_nil
      end

      it_behaves_like 'does not modify span'
    end
  end
end
