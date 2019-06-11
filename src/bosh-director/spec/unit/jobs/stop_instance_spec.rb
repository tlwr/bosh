require 'spec_helper'

module Bosh::Director
  describe Jobs::StopInstance do
    describe 'DJ job class expectations' do
      let(:job_type) { :stop_instance }
      let(:queue) { :normal }
      it_behaves_like 'a DJ job'
    end

    let(:manifest) { Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups }
    let(:deployment) { Models::Deployment.make(name: 'simple', manifest: YAML.dump(manifest)) }
    let(:instance) { Models::Instance.make(deployment: deployment, job: 'foobar') }
    let(:vm_model) { Models::Vm.make(instance_id: instance_model.id) }
    let(:task) { Models::Task.make(id: 42) }
    let(:task_writer) { TaskDBWriter.new(:event_output, task.id) }
    let(:event_log) { EventLog::Log.new(task_writer) }
    let(:cloud_config) { Models::Config.make(:cloud_with_manifest_v2) }

    before do
      Models::VariableSet.make(deployment: deployment)
      deployment.add_cloud_config(cloud_config)
      release = Models::Release.make(name: 'bosh-release')
      release_version = Models::ReleaseVersion.make(version: '0.1-dev', release: release)
      template1 = Models::Template.make(name: 'foobar', release: release)
      release_version.add_template(template1)
      allow(Config).to receive(:event_log).and_call_original
    end

    describe 'perform' do
      it 'should stop the instance' do
        job = Jobs::StopInstance.new(instance.id, {})
        expect(instance.state).to eq 'started'
        job.perform
        # we don't actually update this in the database, we only call agent_client.stop in the stopper
        expect(instance.state).to eq 'stopped'
      end
    end
  end
end
