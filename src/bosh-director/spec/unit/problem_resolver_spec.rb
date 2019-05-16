require 'spec_helper'

module Bosh::Director
  describe ProblemResolver do
    let(:event_manager) { Bosh::Director::Api::EventManager.new(true) }
    let(:job) { instance_double(Bosh::Director::Jobs::BaseJob, username: 'user', task_id: task.id, event_manager: event_manager) }
    let(:cloud_factory) { instance_double(Bosh::Director::CloudFactory) }
    let(:cloud) { instance_double(Bosh::Clouds::ExternalCpi) }
    let(:task) { Bosh::Director::Models::Task.make(id: 42, username: 'user') }
    let(:task_writer) { Bosh::Director::TaskDBWriter.new(:event_output, task.id) }
    let(:event_log) { Bosh::Director::EventLog::Log.new(task_writer) }
    let(:update_deployment) { double }
    let(:parallel_update_config) { instance_double('Bosh::Director::DeploymentPlan::UpdateConfig', serial?: false) }
    #TODO: do we need 5 igs? isn't it possible to reset the dataase after each test such that
    #the job-count doesn't get incremented between tests
    let(:igs) do
      igs = []
      (1..6).each do |i|
        igs << instance_double('Bosh::Director::DeploymentPlan::InstanceGroup', name: "job-#{i}", update: parallel_update_config)
      end
      igs
    end

    before(:each) do
      @deployment = Models::Deployment.make(name: 'mycloud')

      allow(Bosh::Director::Jobs::UpdateDeployment).to receive(:new).and_return(update_deployment)
      allow(update_deployment).to receive_message_chain(:deployment_plan, :instance_groups).and_return(igs)
      allow(parallel_update_config).to receive(:max_in_flight).and_return(5)

      allow(Bosh::Director::Config).to receive(:current_job).and_return(job)
      allow(Bosh::Director::Config).to receive(:event_log).and_return(event_log)
      allow(Bosh::Director::Config).to receive(:parallel_problem_resolution).and_return(true)

      allow(Bosh::Director::CloudFactory).to receive(:create).and_return(cloud_factory)
      allow(cloud_factory).to receive(:get).with('', nil).and_return(cloud)
    end

    def make_resolver(deployment)
      ProblemResolver.new(deployment)
    end

    def inactive_disk(id, deployment_id = nil)
      Models::DeploymentProblem.make(deployment_id: deployment_id || @deployment.id,
                                     resource_id: id,
                                     type: 'inactive_disk',
                                     state: 'open')
    end

    describe '#apply_resolutions' do
      context 'when execution succeeds' do
        let(:number_of_instance_groups_with_problems) { 2 }
        let(:max_threads) { 10 }
        before do
          allow(Bosh::Director::Config).to receive(:max_threads).and_return(max_threads)
        end

        context 'when parallel resurrection is turned on' do
          it 'resolves the problems parallel' do
            test_apply_resolutions
            # outer thread pool
            expect(ThreadPool).to have_received(:new).once.with(max_threads: [number_of_instance_groups_with_problems, max_threads].min)
            # inner thread pools
            expect(ThreadPool).to have_received(:new).twice.with(max_threads: 1)
          end
        end

        context 'when parallel resurrection is turned off' do
          before do
            allow(Bosh::Director::Config).to receive(:parallel_problem_resolution).and_return(false)
          end
          it 'resolves the problems serial' do
            test_apply_resolutions
            expect(ThreadPool).not_to have_received(:new)
          end
        end

        def test_apply_resolutions
          disks = []
          problems = []

          agent = double('agent')
          expect(agent).to receive(:list_disk).and_return([])
          expect(cloud).to receive(:detach_disk).exactly(1).times

          allow(AgentClient).to receive(:with_agent_id).and_return(agent)

          number_of_instance_groups_with_problems.times do
            # instance = Models::Instance.make(job: ig_1.name, deployment_id: @deployment.id)
            # , instance_id: instance.id)
            disk = Models::PersistentDisk.make(active: false)
            disks << disk
            problems << inactive_disk(disk.id)
          end

          resolver = make_resolver(@deployment)

          expect(resolver).to receive(:track_and_log).with(/Disk 'disk-cid-\d+' \(0M\) for instance 'job-\d+\/uuid-\d+ \(\d+\)' is inactive \(.*\): .*/).twice.and_call_original

          expect(resolver.apply_resolutions(problems[0].id.to_s => 'delete_disk', problems[1].id.to_s => 'ignore'))
            .to eq([2, nil])

          expect(Models::PersistentDisk.find(id: disks[0].id)).to be_nil
          expect(Models::PersistentDisk.find(id: disks[1].id)).not_to be_nil

          expect(Models::DeploymentProblem.filter(state: 'open').count).to eq(0)
        end

        it 'logs already resolved problem' do
          disk = Models::PersistentDisk.make
          problem = Models::DeploymentProblem.make(deployment_id: @deployment.id,
                                                   resource_id: disk.id,
                                                   type: 'inactive_disk',
                                                   state: 'resolved')
          resolver = make_resolver(@deployment)
          expect(resolver).to receive(:track_and_log).once.with("Ignoring problem #{problem.id} (state is 'resolved')")
          count, err_message = resolver.apply_resolutions(problem.id.to_s => 'delete_disk')
          expect(count).to eq(0)
          expect(err_message).to be_nil
        end

        it 'ignores non-existing problems' do
          resolver = make_resolver(@deployment)
          expect(resolver.apply_resolutions(
            '9999999' => 'ignore',
            '318' => 'do_stuff',
          )).to eq([0, nil])
        end
      end

      context 'when problem resolution fails' do
        let(:backtrace) { anything }
        let(:disk) { Models::PersistentDisk.make(active: false) }
        let(:problem) { inactive_disk(disk.id) }
        let(:resolver) { make_resolver(@deployment) }

        it 'rescues ProblemHandlerError and logs' do
          expect(resolver).to receive(:track_and_log)
            .and_raise(Bosh::Director::ProblemHandlerError.new('Resolution failed'))
          expect(logger).to receive(:error).with("Error resolving problem '#{problem.id}': Resolution failed")
          expect(logger).to receive(:error).with(backtrace)

          count, error_message = resolver.apply_resolutions(problem.id.to_s => 'ignore')

          expect(error_message).to eq("Error resolving problem '#{problem.id}': Resolution failed")
          expect(count).to eq(1)
        end

        it 'rescues StandardError and logs' do
          expect(ProblemHandlers::Base).to receive(:create_from_model)
            .and_raise(StandardError.new('Model creation failed'))
          expect(logger).to receive(:error).with("Error resolving problem '#{problem.id}': Model creation failed")
          expect(logger).to receive(:error).with(backtrace)

          count, error_message = resolver.apply_resolutions(problem.id.to_s => 'ignore')

          expect(error_message).to eq("Error resolving problem '#{problem.id}': Model creation failed")
          expect(count).to eq(0)
        end
      end
    end
  end
end
