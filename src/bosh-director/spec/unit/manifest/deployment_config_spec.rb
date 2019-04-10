require 'spec_helper'

module Bosh::Director
  describe DeploymentConfig do
    subject do
      DeploymentConfig.new(manifest_hash, team_names)
    end

    let(:team_names) { nil }

    let(:manifest_hash) do
      {
        'instance_groups' => {
          'lifecycle' => 'errand',
          'name' => 'test_instance_group',
          'azs' => ['az1'],
          'stemcell' => 'default',
          'jobs' => [
            {
              'release' => 'test_release',
              'name' => 'test_job',
            },
          ],
          'networks' => [
            {
              'name' => 'default',
            },
          ],
        },
        'update' => {
        },
        'stemcells' => [
          {
            'alias' => 'default',
            'os' => 'ubuntu-trusty',
            'version' => 1234,
          },
          {
            'alias' => 'xenial',
            'os' => 'ubuntu-xenial',
            'version' => 5678,
          },
        ],
      }
    end

    describe :serial do
      context 'when serial is not set' do
        it 'returns true' do
          expect(subject.serial).to eq(true)
        end
      end
      context 'when serial is set' do
        before do
          manifest_hash['update']['serial'] = false
        end
        it 'returns false when set to false' do
          expect(subject.serial).to eq(false)
        end
      end
    end
  end
end
