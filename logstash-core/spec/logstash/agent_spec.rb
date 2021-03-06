# encoding: utf-8
require "spec_helper"
require "stud/temporary"
require "logstash/inputs/generator"
require_relative "../support/mocks_classes"

describe LogStash::Agent do

  let(:logger) { double("logger") }
  let(:agent_settings) { LogStash::SETTINGS }
  let(:agent_args) { {} }
  let(:pipeline_settings) { agent_settings.clone }
  let(:pipeline_args) { {} }
  let(:config_file) { Stud::Temporary.pathname }
  let(:config_file_txt) { "input { generator { count => 100000 } } output { }" }

  subject { LogStash::Agent.new(agent_settings) }

  before :each do
    [:info, :warn, :error, :fatal, :debug].each do |level|
      allow(logger).to receive(level)
    end
    [:info?, :warn?, :error?, :fatal?, :debug?].each do |level|
      allow(logger).to receive(level)
    end
    File.open(config_file, "w") { |f| f.puts config_file_txt }
    agent_args.each do |key, value|
      agent_settings.set(key, value)
      pipeline_settings.set(key, value)
    end
    pipeline_args.each do |key, value|
      pipeline_settings.set(key, value)
    end
    #subject.logger = logger
  end

  after :each do
    LogStash::SETTINGS.reset
    File.unlink(config_file)
  end

  it "fallback to hostname when no name is provided" do
    expect(LogStash::Agent.new.node_name).to eq(Socket.gethostname)
  end

  describe "register_pipeline" do
    let(:pipeline_id) { "main" }
    let(:config_string) { "input { } filter { } output { }" }
    let(:agent_args) do
      { 
        "config.string" => config_string,
        "config.reload.automatic" => true,
        "config.reload.interval" => 0.01,
	"pipeline.workers" => 4,
      }
    end

    it "should delegate settings to new pipeline" do
      expect(LogStash::Pipeline).to receive(:new) do |arg1, arg2|
        expect(arg1).to eq(config_string)
	expect(arg2.to_hash).to include(agent_args)
      end
      subject.register_pipeline(pipeline_id, agent_settings)
    end
  end

  describe "#execute" do
    let(:config_file_txt) { "input { generator { count => 100000 } } output { }" }

    before :each do
      allow(subject).to receive(:start_webserver).and_return(false)
      allow(subject).to receive(:stop_webserver).and_return(false)
    end

    context "when auto_reload is false" do
      let(:agent_args) do
        {
          "config.reload.automatic" => false,
          "path.config" => config_file
        }
      end
      let(:pipeline_id) { "main" }

      before(:each) do
        subject.register_pipeline(pipeline_id, pipeline_settings)
      end

      context "if state is clean" do
        before :each do
          allow(subject).to receive(:running_pipelines?).and_return(true)
          allow(subject).to receive(:sleep)
          allow(subject).to receive(:clean_state?).and_return(false)
        end

        it "should not reload_state!" do
          expect(subject).to_not receive(:reload_state!)
          t = Thread.new { subject.execute }
          sleep 0.1
          Stud.stop!(t)
          t.join
          subject.shutdown
        end
      end

      context "when calling reload_state!" do
        context "with a config that contains reload incompatible plugins" do
          let(:second_pipeline_config) { "input { stdin {} } filter { } output { }" }

          it "does not upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.ready?
            expect(subject).to_not receive(:upgrade_pipeline)
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            subject.send(:reload_state!)
            sleep 0.1
            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end

        context "with a config that does not contain reload incompatible plugins" do
          let(:second_pipeline_config) { "input { generator { } } filter { } output { }" }

          it "does upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.ready?
            expect(subject).to receive(:upgrade_pipeline).once.and_call_original
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            subject.send(:reload_state!)
            sleep 0.1
            Stud.stop!(t)
            t.join

            subject.shutdown
          end
        end
      end
    end

    context "when auto_reload is true" do
      let(:agent_args) do
        {
          "config.reload.automatic" => true,
          "config.reload.interval" => 0.01,
          "path.config" => config_file,
        }
      end
      let(:pipeline_id) { "main" }

      before(:each) do
        subject.register_pipeline(pipeline_id, pipeline_settings)
      end

      context "if state is clean" do
        it "should periodically reload_state" do
          allow(subject).to receive(:clean_state?).and_return(false)
          expect(subject).to receive(:reload_state!).at_least(3).times
          t = Thread.new { subject.execute }
          sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.ready?
          sleep 0.1
          Stud.stop!(t)
          t.join
          subject.shutdown
        end
      end

      context "when calling reload_state!" do
        context "with a config that contains reload incompatible plugins" do
          let(:second_pipeline_config) { "input { stdin {} } filter { } output { }" }

          it "does not upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.ready?
            expect(subject).to_not receive(:upgrade_pipeline)
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            sleep 0.1
            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end

        context "with a config that does not contain reload incompatible plugins" do
          let(:second_pipeline_config) { "input { generator { } } filter { } output { }" }

          it "does upgrade the new config" do
            t = Thread.new { subject.execute }
            sleep 0.01 until subject.running_pipelines? && subject.pipelines.values.first.ready?
            expect(subject).to receive(:upgrade_pipeline).once.and_call_original
            File.open(config_file, "w") { |f| f.puts second_pipeline_config }
            sleep 0.1
            Stud.stop!(t)
            t.join
            subject.shutdown
          end
        end
      end
    end
  end

  describe "#reload_state!" do
    let(:pipeline_id) { "main" }
    let(:first_pipeline_config) { "input { } filter { } output { }" }
    let(:second_pipeline_config) { "input { generator {} } filter { } output { }" }
    let(:pipeline_args) { {
      "config.string" => first_pipeline_config,
      "pipeline.workers" => 4
    } }

    before(:each) do
      subject.register_pipeline(pipeline_id, pipeline_settings)
    end

    context "when fetching a new state" do
      it "upgrades the state" do
        expect(subject).to receive(:fetch_config).and_return(second_pipeline_config)
        expect(subject).to receive(:upgrade_pipeline).with(pipeline_id, kind_of(LogStash::Pipeline))
        subject.send(:reload_state!)
      end
    end
    context "when fetching the same state" do
      it "doesn't upgrade the state" do
        expect(subject).to receive(:fetch_config).and_return(first_pipeline_config)
        expect(subject).to_not receive(:upgrade_pipeline)
        subject.send(:reload_state!)
      end
    end
  end

  describe "Environment Variables In Configs" do
    let(:pipeline_config) { "input { generator { message => '${FOO}-bar' } } filter { } output { }" }
    let(:agent_args) { {
      "config.reload.automatic" => false,
      "config.reload.interval" => 0.01,
      "config.string" => pipeline_config
    } }
    let(:pipeline_id) { "main" }

    context "environment variable templating" do
      before :each do
        @foo_content = ENV["FOO"]
        ENV["FOO"] = "foo"
      end

      after :each do
        ENV["FOO"] = @foo_content
      end

      it "doesn't upgrade the state" do
        allow(subject).to receive(:fetch_config).and_return(pipeline_config)
        subject.register_pipeline(pipeline_id, pipeline_settings)
        expect(subject.pipelines[pipeline_id].inputs.first.message).to eq("foo-bar")
      end
    end
  end

  describe "#upgrade_pipeline" do
    let(:pipeline_id) { "main" }
    let(:pipeline_config) { "input { } filter { } output { }" }
    let(:pipeline_args) { {
      "config.string" => pipeline_config,
      "pipeline.workers" => 4
    } }
    let(:new_pipeline_config) { "input { generator {} } output { }" }

    before(:each) do
      subject.register_pipeline(pipeline_id, pipeline_settings)
    end

    context "when the upgrade fails" do
      before :each do
        allow(subject).to receive(:fetch_config).and_return(new_pipeline_config)
        allow(subject).to receive(:create_pipeline).and_return(nil)
        allow(subject).to receive(:stop_pipeline)
      end

      it "leaves the state untouched" do
        subject.send(:reload_state!)
        expect(subject.pipelines[pipeline_id].config_str).to eq(pipeline_config)
      end

      context "and current state is empty" do
        it "should not start a pipeline" do
          expect(subject).to_not receive(:start_pipeline)
          subject.send(:reload_state!)
        end
      end
    end

    context "when the upgrade succeeds" do
      let(:new_config) { "input { generator { count => 1 } } output { }" }
      before :each do
        allow(subject).to receive(:fetch_config).and_return(new_config)
        allow(subject).to receive(:stop_pipeline)
      end
      it "updates the state" do
        subject.send(:reload_state!)
        expect(subject.pipelines[pipeline_id].config_str).to eq(new_config)
      end
      it "starts the pipeline" do
        expect(subject).to receive(:stop_pipeline)
        expect(subject).to receive(:start_pipeline)
        subject.send(:reload_state!)
      end
    end
  end

  describe "#fetch_config" do
    let(:cli_config) { "filter { drop { } } " }
    let(:agent_args) { { "config.string" => cli_config, "path.config" => config_file } }

    it "should join the config string and config path content" do
      fetched_config = subject.send(:fetch_config, agent_settings)
      expect(fetched_config.strip).to eq(cli_config + IO.read(config_file).strip)
    end
  end

  context "#started_at" do
    it "return the start time when the agent is started" do
      expect(described_class::STARTED_AT).to be_kind_of(Time)
    end
  end

  context "#uptime" do
    it "return the number of milliseconds since start time" do
      expect(subject.uptime).to be >= 0
    end
  end


  context "metrics after config reloading" do
    let(:config) { "input { generator { } } output { dummyoutput { } }" }
    let(:new_config_generator_counter) { 500 }
    let(:new_config) { "input { generator { count => #{new_config_generator_counter} } } output { dummyoutput2 {} }" }
    let(:config_path) do
      f = Stud::Temporary.file
      f.write(config)
      f.close
      f.path
    end
    let(:interval) { 0.2 }
    let(:pipeline_args) do
      {
        "pipeline.workers" => 4,
        "path.config" => config_path
      }
    end

    let(:agent_args) do
      super.merge({ "config.reload.automatic" => true,
                    "config.reload.interval" => interval,
                    "metric.collect" => true })
    end 

    # We need to create theses dummy classes to know how many
    # events where actually generated by the pipeline and successfully send to the output.
    # Theses values are compared with what we store in the metric store.
    let!(:dummy_output) { DummyOutput.new }
    let!(:dummy_output2) { DummyOutput.new }
    class DummyOutput2 < LogStash::Outputs::Base; end

    before :each do
      allow(DummyOutput).to receive(:new).at_least(:once).with(anything).and_return(dummy_output)
      allow(DummyOutput2).to receive(:new).at_least(:once).with(anything).and_return(dummy_output2)

      allow(LogStash::Plugin).to receive(:lookup).with("input", "generator").and_return(LogStash::Inputs::Generator)
      allow(LogStash::Plugin).to receive(:lookup).with("codec", "plain").and_return(LogStash::Codecs::Plain)
      allow(LogStash::Plugin).to receive(:lookup).with("output", "dummyoutput").and_return(DummyOutput)
      allow(LogStash::Plugin).to receive(:lookup).with("output", "dummyoutput2").and_return(DummyOutput2)

      @abort_on_exception = Thread.abort_on_exception
      Thread.abort_on_exception = true

      @t = Thread.new do
        subject.register_pipeline("main",  pipeline_settings)
        subject.execute
      end

      sleep(2)
    end

    after :each do
      begin
        subject.shutdown
        Stud.stop!(@t)
        @t.join
      ensure
        Thread.abort_on_exception = @abort_on_exception
      end
    end

    it "resets the metric collector" do
      # We know that the store has more events coming in.
      i = 0
      while dummy_output.events.size <= new_config_generator_counter
        i += 1
        raise "Waiting too long!" if i > 20
        sleep(0.1)
      end

      snapshot = subject.metric.collector.snapshot_metric
      expect(snapshot.metric_store.get_with_path("/stats/events")[:stats][:events][:in].value).to be > new_config_generator_counter

      # update the configuration and give some time to logstash to pick it up and do the work
      # Also force a flush to disk to make sure ruby reload it.
      File.open(config_path, "w") do |f|
        f.write(new_config)
        f.fsync
      end

      sleep(interval * 3) # Give time to reload the config
      
      # be eventually consistent.
      sleep(0.01) while dummy_output2.events.size < new_config_generator_counter

      snapshot = subject.metric.collector.snapshot_metric
      value = snapshot.metric_store.get_with_path("/stats/events")[:stats][:events][:in].value
      expect(value).to eq(new_config_generator_counter)
    end
  end
end
