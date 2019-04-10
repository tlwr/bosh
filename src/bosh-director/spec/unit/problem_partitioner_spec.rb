require 'spec_helper'

module Bosh::Director
  describe ProblemPartitioner do
    let(:subject) do
      described_class.new
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
          'instance_groups' => problem_partition_layout.each_with_index.map do |x, i|
            {
              'name' => "instance_group_#{i}",
            }
          end,
        }
    end

    context 'when deployment contains a single instance group with two problems' do
      let(:problem_partition_layout) { [2] }
      it 'returns a single group of problems' do
        expected_partition = ProblemPartition.new(problems, 'instance_group_0', true)
        expect(subject.partition_by_instance_group(deployment, problems)).to eq([expected_partition])
      end
    end

    context 'when deployment contains 2 instance groups with 1 problem each' do
      let(:problem_partition_layout) { [1, 1] }
      it 'returns two groups of problems' do
        expected_partitions = [
          ProblemPartition.new(problems[0..0], 'instance_group_0', true),
          ProblemPartition.new(problems[1..1], 'instance_group_1', true),
        ]
        expect(subject.partition_by_instance_group(deployment, problems)).to eq(expected_partitions)
      end
    end

    context 'when deployment contains 3 instance groups one of which has no problem' do
      let(:problem_partition_layout) { [2, 0, 3] }
      it 'returns two groups of problems' do
        expected_partitions = [
          ProblemPartition.new(problems[0..1], 'instance_group_0', true),
          ProblemPartition.new([], 'instance_group_1', true),
          ProblemPartition.new(problems[2..5], 'instance_group_2', true),
        ]
        expect(subject.partition_by_instance_group(deployment, problems)).to eq(expected_partitions)
      end
    end

    context 'when serial is set for instance_groups' do
      let(:problem_partition_layout) { [2, 0, 3] }
      before do
        manifest['instance_groups'][0]['update'] = { 'serial' => false }
      end
      it 'sets the serial property accordingly' do
        expected_partitions = [
          ProblemPartition.new(problems[0..1], 'instance_group_0', false),
          ProblemPartition.new([], 'instance_group_1', true),
          ProblemPartition.new(problems[2..5], 'instance_group_2', true),
        ]
        expect(subject.partition_by_instance_group(deployment, problems)).to eq(expected_partitions)
      end
    end
  end
end
