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

    before(:each) do
      @deployment = Models::Deployment.make(name: 'mycloud')
      @other_deployment = Models::Deployment.make(name: 'othercloud')
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

    let(:instances) do
      problem_partition_layout.each_with_index.map do |x, i|
        (0..x - 1).map do
          Bosh::Director::Models::Instance.make(job: "instance_group_#{i}")
        end
      end
    end

    let(:partition_problems) do
      probs = []
      problem_partition_layout.each_with_index.map do |x, i|
        (0..x - 1).each do |j|
          probs << Models::DeploymentProblem.make(deployment_id: @deployment.id,
                                                  resource_id: instances[i][j].id,
                                                  type: 'recreate_vm',
                                                  state: 'open')
        end
      end
      probs
    end

    describe '#apply_resolutions' do
      let(:problem_partition_layout) { [2, 2, 2, 1, 2] }
      let(:problem_partitions) do
      [
        [ProblemPartition.new(partition_problems[0..1], 'instance_group_0', true, 2)],
        [
          ProblemPartition.new(partition_problems[2..3], 'instance_group_1', false, 3),
          ProblemPartition.new(partition_problems[4..5], 'instance_group_2', false, 4),
        ],
        [ProblemPartition.new(partition_problems[6..6], 'instance_group_3', true, 3)],
        [ProblemPartition.new(partition_problems[7..8], 'instance_group_4', true, 5)],
      ]
      end
      context 'when execution succeeds' do
        before do
          allow(Bosh::Director::Config).to receive(:max_threads).and_return(5)
        end

        context 'when parallel resurrection is turned on' do
          it 'resolves the problems in serial' do
            current_problem_partitions = problem_partitions
            allow(ProblemPartitioner).to receive(:partition).and_return(current_problem_partitions)

            sequel_dataset = instance_double('Sequel::Dataset')
            allow(Models::DeploymentProblem).to receive(:where).and_return(sequel_dataset)

            problems = partition_problems[0..8]
            allow(sequel_dataset).to receive(:all).and_return(problems)

            resolver = make_resolver(@deployment)

            problem_partition_pool = double('problem_partition_pool')
            expect(ThreadPool).to receive(:new).with(max_threads: 5).once.and_return(problem_partition_pool)
            expect(problem_partition_pool).to receive(:wrap).ordered.once.and_yield(problem_partition_pool)
            expect(problem_partition_pool).to receive(:process).exactly(2).times.and_yield

            expect(resolver).to receive(:process_problem_partition).once.with(current_problem_partitions[0][0]).and_call_original
            expect(resolver).to receive(:process_problem_partition).once.with(current_problem_partitions[1][0]).and_call_original
            expect(resolver).to receive(:process_problem_partition).once.with(current_problem_partitions[1][1]).and_call_original
            expect(resolver).to receive(:process_problem_partition).once.with(current_problem_partitions[2][0]).and_call_original
            expect(resolver).to receive(:process_problem_partition).once.with(current_problem_partitions[3][0]).and_call_original

            instance_group_1_pool = double('instance_group_1_pool')
            expect(ThreadPool).to receive(:new).with(max_threads: 3).once.and_return(instance_group_1_pool)
            expect(instance_group_1_pool).to receive(:wrap).once.and_yield(instance_group_1_pool)
            expect(instance_group_1_pool).to receive(:process).exactly(2).times.and_yield

            instance_group_2_pool = double('instance_group_2_pool')
            expect(ThreadPool).to receive(:new).with(max_threads: 4).once.and_return(instance_group_2_pool)
            expect(instance_group_2_pool).to receive(:wrap).once.and_yield(instance_group_2_pool)
            expect(instance_group_2_pool).to receive(:process).exactly(2).times.and_yield

            instance_group_4_pool = double('instance_group_4_pool')
            expect(ThreadPool).to receive(:new).with(max_threads: 5).once.and_return(instance_group_4_pool)
            expect(instance_group_4_pool).to receive(:wrap).once.and_yield(instance_group_4_pool)
            expect(instance_group_4_pool).to receive(:process).exactly(2).times.and_yield

            expect(resolver).to receive(:process_problem).exactly(9).times

            resolver.apply_resolutions({})
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

          2.times do
            disk = Models::PersistentDisk.make(active: false)
            disks << disk
            problems << inactive_disk(disk.id)
          end

          resolver = make_resolver(@deployment)

          expect(resolver).to receive(:track_and_log).with(/Disk 'disk-cid-\d+' \(0M\) for instance 'job-\d+\/uuid-\d+ \(\d+\)' is inactive \(.*\): .*/).twice.and_call_original

          allow(Bosh::Director::ProblemPartitioner).to receive(:partition).and_return([[ProblemPartition.new(problems, 'instance_group_0', true, 5)]])
          expect(resolver.apply_resolutions(problems[0].id.to_s => 'delete_disk', problems[1].id.to_s => 'ignore'))
            .to eq([2, nil])

          expect(Models::PersistentDisk.find(id: disks[0].id)).to be_nil
          expect(Models::PersistentDisk.find(id: disks[1].id)).not_to be_nil

          expect(Models::DeploymentProblem.filter(state: 'open').count).to eq(0)
        end

        it 'notices and logs extra resolutions' do
          disks = (1..3).map { |_| Models::PersistentDisk.make(active: false) }

          problems = [
            inactive_disk(disks[0].id),
            inactive_disk(disks[1].id),
            inactive_disk(disks[2].id, @other_deployment.id),
          ]

          resolver1 = make_resolver(@deployment)
          allow(Bosh::Director::ProblemPartitioner).to receive(:partition).and_return([[ProblemPartition.new(problems, 'instance_group_0', true, 5)]])
          expect(resolver1.apply_resolutions(problems[0].id.to_s => 'ignore', problems[1].id.to_s => 'ignore')).to eq([2, nil])

          resolver2 = make_resolver(@deployment)

          messages = []
          expect(resolver2).to receive(:track_and_log).exactly(3).times { |message| messages << message }
          resolver2.apply_resolutions(
            problems[0].id.to_s => 'ignore',
            problems[1].id.to_s => 'ignore',
            problems[2].id.to_s => 'ignore',
            '9999999' => 'ignore',
            '318' => 'do_stuff',
          )

          expect(messages).to match_array([
                                            "Ignoring problem #{problems[0].id} (state is 'resolved')",
                                            "Ignoring problem #{problems[1].id} (state is 'resolved')",
                                            "Ignoring problem #{problems[2].id} (not a part of this deployment)",
                                          ])
        end
      end

      context 'when execution fails' do
        it 'raises error and logs' do
          backtrace = anything
          disk = Models::PersistentDisk.make(active: false)
          problem = inactive_disk(disk.id)
          resolver = make_resolver(@deployment)

          expect(resolver).to receive(:track_and_log)
            .and_raise(Bosh::Director::ProblemHandlerError.new('Resolution failed'))
          expect(logger).to receive(:error).with("Error resolving problem '#{problem.id}': Resolution failed")
          expect(logger).to receive(:error).with(backtrace)

          allow(Bosh::Director::ProblemPartitioner).to receive(:partition).and_return([[ProblemPartition.new([problem], 'instance_group_0', true, 5)]])
          count, error_message = resolver.apply_resolutions(problem.id.to_s => 'ignore')

          expect(error_message).to eq("Error resolving problem '#{problem.id}': Resolution failed")
          expect(count).to eq(1)
        end
      end

      context 'when execution fails because of other errors' do
        it 'raises error and logs' do
          backtrace = anything
          disk = Models::PersistentDisk.make(active: false)
          problem = inactive_disk(disk.id)
          resolver = make_resolver(@deployment)

          expect(ProblemHandlers::Base).to receive(:create_from_model)
            .and_raise(StandardError.new('Model creation failed'))
          expect(logger).to receive(:error).with("Error resolving problem '#{problem.id}': Model creation failed")
          expect(logger).to receive(:error).with(backtrace)

          allow(Bosh::Director::ProblemPartitioner).to receive(:partition).and_return([[ProblemPartition.new([problem], 'instance_group_0', true, 5)]])
          count, error_message = resolver.apply_resolutions(problem.id.to_s => 'ignore')

          expect(error_message).to eq("Error resolving problem '#{problem.id}': Model creation failed")
          expect(count).to eq(0)
        end
      end
    end
  end
end
