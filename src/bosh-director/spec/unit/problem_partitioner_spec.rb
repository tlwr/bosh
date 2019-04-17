require 'spec_helper'

module Bosh::Director
  describe ProblemPartitioner do
    let(:subject) do
      described_class
    end
    let(:deployment) {Models::Deployment.make(name: 'mydeployment', manifest: YAML.dump(manifest))}
    let(:instances) do
      problem_partition_layout.each_with_index.map do |x, i|
        (0..x-1).map do
          Bosh::Director::Models::Instance.make( job: "instance_group_#{i}" )
        end
      end
    end
    let(:problems) do
      probs = []
      problem_partition_layout.each_with_index.map do |x, i|
        (0..x-1).each do |j|
          probs << Models::DeploymentProblem.make(deployment_id: deployment.id,
                                                  resource_id: instances[i][j].id,
                                                  type: 'recreate_vm',
                                                  state: 'open')
        end
      end
      probs
    end
    let(:manifest) do
      {
        'update' => {
          'max_in_flight' => 1,
        },
        'instance_groups' => problem_partition_layout.each_with_index.map do |_, i|
          {
            'name' => "instance_group_#{i}",
          }
        end,
      }
    end

    describe '#partition' do
      let(:problem_partition_layout) { [2, 2, 3, 2, 0, 2] }
      before do
        manifest['instance_groups'][1]['update'] = { 'serial' => false, 'max_in_flight' => 2 }
        manifest['instance_groups'][2]['update'] = { 'serial' => false, 'max_in_flight' => 3 }
        manifest['instance_groups'][4]['update'] = { 'serial' => false, 'max_in_flight' => 4 }
        manifest['instance_groups'][5]['update'] = { 'serial' => false, 'max_in_flight' => 5 }
      end

      it 'partitions by serial and skips instance_groups without problems' do
        expected_problems_order = [
          [ProblemPartition.new(problems[0..1], 'instance_group_0', true, 1)],
          [
            ProblemPartition.new(problems[2..3], 'instance_group_1', false, 2),
            ProblemPartition.new(problems[4..6], 'instance_group_2', false, 3),
          ],
          [ProblemPartition.new(problems[7..8], 'instance_group_3', true, 1)],
          [
            ProblemPartition.new([], 'instance_group_4', false, 4),
            ProblemPartition.new(problems[9..10], 'instance_group_5', false, 5),
          ],
        ]
        expect(subject.partition(deployment, problems)).to eq(expected_problems_order)
      end
    end
  end
end
