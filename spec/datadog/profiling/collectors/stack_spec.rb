# typed: ignore

require 'datadog/profiling/spec_helper'
require 'datadog/profiling/collectors/stack'

# This file has a few lines that cannot be broken because we want some things to have the same line number when looking
# at their stack traces. Hence, we disable Rubocop's complaints here.
#
# rubocop:disable Layout/LineLength
RSpec.describe Datadog::Profiling::Collectors::Stack do
  before { skip_if_profiling_not_supported(self) }

  subject(:collectors_stack) { described_class.new }

  let(:recorder) { Datadog::Profiling::StackRecorder.new }
  let(:metric_values) { { 'cpu-time' => 123, 'cpu-samples' => 456, 'wall-time' => 789 } }
  let(:labels) { { 'label_a' => 'value_a', 'label_b' => 'value_b' }.to_a }

  let(:pprof_data) { recorder.serialize.last }
  let(:decoded_profile) { ::Perftools::Profiles::Profile.decode(pprof_data) }

  let(:raw_reference_stack) { stacks.fetch(:reference) }
  let(:reference_stack) do
    raw_reference_stack.map do |location|
      { base_label: location.base_label, path: location.path, lineno: location.lineno }
    end
  end
  let(:gathered_stack) { stacks.fetch(:gathered) }

  # Kernel#sleep is one of many Ruby standard library APIs that are implemented using native code. Older versions of
  # rb_profile_frames did not include these frames in their output, so this spec tests that our rb_profile_frames fixes
  # do correctly overcome this.
  context 'when sampling a sleeping thread' do
    let(:ready_queue) { Queue.new }
    let(:stacks) { { reference: sleeping_thread.backtrace_locations, gathered: sample_and_decode(sleeping_thread) } }
    let(:sleeping_thread) do
      Thread.new(ready_queue) do |ready_queue|
        ready_queue << true
        sleep
      end
    end

    before do
      sleeping_thread
      ready_queue.pop
    end

    after do
      sleeping_thread.kill
      sleeping_thread.join
    end

    it 'matches the Ruby backtrace API' do
      expect(gathered_stack).to eq reference_stack
    end

    it 'has a sleeping frame at the top of the stack' do
      expect(reference_stack.first).to match(hash_including(base_label: 'sleep'))
    end
  end

  # This spec explicitly tests the main thread because an unpatched rb_profile_frames returns one more frame in the
  # main thread than the reference Ruby API. This is almost-surely a bug in rb_profile_frames, since the same frame
  # gets excluded from the reference Ruby API.
  context 'when sampling the main thread' do
    let(:stacks) { { reference: Thread.current.backtrace_locations, gathered: sample_and_decode(Thread.current) } }

    let(:reference_stack) do
      # To make the stacks comparable we slice off the actual Ruby `Thread#backtrace_locations` frame since that part
      # will necessarily be different
      expect(super().first).to match(hash_including(base_label: 'backtrace_locations'))
      super()[1..-1]
    end

    let(:gathered_stack) do
      # To make the stacks comparable we slice off everything starting from `sample_and_decode` since that part will
      # also necessarily be different
      expect(super()[0..2]).to match(
        [
          hash_including(base_label: '_native_sample'),
          hash_including(base_label: 'sample'),
          hash_including(base_label: 'sample_and_decode'),
        ]
      )
      super()[3..-1]
    end

    before do
      expect(Thread.current).to be(Thread.main), 'Unexpected: RSpec is not running on the main thread'
    end

    it 'matches the Ruby backtrace API' do
      expect(gathered_stack).to eq reference_stack
    end
  end

  context 'when sampling a thread with a stack that is deeper than the configured max_frames' do
    let(:max_frames) { 5 }
    let(:target_stack_depth) { 100 }
    let(:thread_with_deep_stack) { thread_with_stack_depth(target_stack_depth) }

    let(:stacks) { { reference: thread_with_deep_stack.backtrace_locations, gathered: sample_and_decode(thread_with_deep_stack, max_frames: max_frames) } }

    after do
      thread_with_deep_stack.kill
      thread_with_deep_stack.join
    end

    it 'gathers exactly max_frames frames' do
      expect(gathered_stack.size).to be max_frames
    end

    it 'matches the Ruby backtrace API up to max_frames - 1' do
      expect(gathered_stack[0...(max_frames - 1)]).to eq reference_stack[0...(max_frames - 1)]
    end

    it 'includes a placeholder frame including the number of skipped frames' do
      placeholder = 1
      omitted_frames = target_stack_depth - max_frames + placeholder

      expect(omitted_frames).to be 96
      expect(gathered_stack.last)
        .to match(hash_including({ base_label: '', path: "96 frames omitted", lineno: 0 }))
    end

    context 'when stack is exactly 1 item deeper than the configured max_frames' do
      let(:target_stack_depth) { 6 }

      it 'includes a placeholder frame stating that 2 frames were omitted' do
        # Why 2 frames omitted and not 1? That's because the placeholder takes over 1 space in the buffer, so
        # if there were 6 frames on the stack and the limit is 5, then 4 of those frames will be present in the output
        expect(gathered_stack.last)
          .to match(hash_including({ base_label: '', path: '2 frames omitted', lineno: 0 }))
      end
    end

    context 'when stack is exactly as deep as the configured max_frames' do
      let(:target_stack_depth) { 5 }

      it 'matches the Ruby backtrace API' do
        expect(gathered_stack).to eq reference_stack
      end
    end

    class DeepStackSimulator
      def initialize(target_depth:, ready_queue:)
        @target_depth = target_depth
        @ready_queue = ready_queue

        define_methods(target_depth)
      end

      # We use this weird approach to both get an exact depth, as well as have a method with a unique name for
      # each depth
      def define_methods(target_depth)
        (1..target_depth).each do |depth|
          next if respond_to?(:"deep_stack_#{depth}")

          eval(%(
            def deep_stack_#{depth}
              if Thread.current.backtrace.size < @target_depth
                deep_stack_#{depth+1}
              else
                @ready_queue << :ready
                sleep
              end
            end
          ))
        end
      end
    end

    def thread_with_stack_depth(depth)
      ready_queue = Queue.new

      # In spec_helper.rb we have a DatadogThreadDebugger which is used to help us debug specs that leak threads.
      # Since in this helper we want to have precise control over how many frames are on the stack of a given thread,
      # we need to take into account that the DatadogThreadDebugger adds one more frame to the stack.
      first_method =
        defined?(DatadogThreadDebugger) && Thread.include?(DatadogThreadDebugger) ? :deep_stack_2 : :deep_stack_1

      thread = Thread.new(&DeepStackSimulator.new(target_depth: depth, ready_queue: ready_queue).method(first_method))
      thread.name = "Deep stack #{depth}" if thread.respond_to?(:name=)
      ready_queue.pop

      thread
    end
  end

  context 'when sampling a dead thread' do
    let(:dead_thread) { Thread.new {}.tap(&:join) }

    let(:stacks) { { reference: dead_thread.backtrace_locations, gathered: sample_and_decode(dead_thread) } }

    it 'gathers an empty stack' do
      expect(gathered_stack).to be_empty
    end
  end

  context 'when sampling a thread with empty locations' do
    let(:ready_pipe) { IO.pipe }
    let(:stacks) { { reference: thread_with_empty_locations.backtrace_locations, gathered: sample_and_decode(thread_with_empty_locations) } }
    let(:finish_pipe) { IO.pipe }

    let(:thread_with_empty_locations) do
      read_ready_pipe, write_ready_pipe = ready_pipe
      read_finish_pipe, write_finish_pipe = finish_pipe

      Process.detach(
        fork do
          # Signal ready to parent
          read_ready_pipe.close
          write_ready_pipe.write('ready')
          write_ready_pipe.close

          # Wait for parent to signal we can exit
          write_finish_pipe.close
          read_finish_pipe.read
          read_finish_pipe.close
        end
      )
    end

    before do
      thread_with_empty_locations

      # Wait for child to signal ready
      read_ready_pipe, write_ready_pipe = ready_pipe
      write_ready_pipe.close
      expect(read_ready_pipe.read).to eq 'ready'
      read_ready_pipe.close

      expect(reference_stack).to be_empty
    end

    after do
      # Signal child to exit
      finish_pipe.map(&:close)

      thread_with_empty_locations.join
    end

    it 'gathers a one-element stack with a "In native code" placeholder' do
      expect(gathered_stack).to contain_exactly({ base_label: '', path: 'In native code', lineno: 0 })
    end
  end

  context 'when trying to sample something which is not a thread' do
    it 'raises a TypeError' do
      expect { collectors_stack.sample(:not_a_thread, recorder, metric_values, labels) }.to raise_error(TypeError)
    end
  end

  context 'when max_frames is too small' do
    it 'raises an ArgumentError' do
      expect { collectors_stack.sample(Thread.current, recorder, metric_values, labels, max_frames: 4) }.to raise_error(ArgumentError)
    end
  end

  context 'when max_frames is too large' do
    it 'raises an ArgumentError' do
      expect { collectors_stack.sample(Thread.current, recorder, metric_values, labels, max_frames: 10_001) }.to raise_error(ArgumentError)
    end
  end

  def sample_and_decode(thread, max_frames: 400)
    collectors_stack.sample(thread, recorder, metric_values, labels, max_frames: max_frames)

    expect(decoded_profile.sample.size).to be 1
    sample = decoded_profile.sample.first

    sample.location_id.map { |location_id| decode_frame(decoded_profile, location_id) }
  end

  def decode_frame(decoded_profile, location_id)
    strings = decoded_profile.string_table
    location = decoded_profile.location.find { |loc| loc.id == location_id }
    expect(location.line.size).to be 1
    line_entry = location.line.first
    function = decoded_profile.function.find { |func| func.id == line_entry.function_id }

    { base_label: strings[function.name], path: strings[function.filename], lineno: line_entry.line }
  end
end
# rubocop:enable Layout/LineLength
