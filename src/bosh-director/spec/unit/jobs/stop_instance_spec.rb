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
    let(:vm_model) { Models::Vm.make(instance: instance, active: true) }
    let(:task) { Models::Task.make(id: 42) }
    let(:task_writer) { TaskDBWriter.new(:event_output, task.id) }
    let(:event_log) { EventLog::Log.new(task_writer) }
    let(:cloud_config) { Models::Config.make(:cloud_with_manifest_v2) }
    let(:variables_interpolator) { ConfigServer::VariablesInterpolator.new }
    let(:deployment_plan_instance) do
      instance_double(DeploymentPlan::Instance,
                      template_hashes: nil,
                      rendered_templates_archive: nil,
                      configuration_hash: nil
      )
    end

    let(:agent_client) { instance_double(AgentClient, run_script: nil, drain: 0, stop: nil) }
    let(:spec) do
      {
        'vm_type' => {
          'name' => 'vm-type-name',
          'cloud_properties' => {},
        },
        'stemcell' => {
          'name' => 'stemcell-name',
          'version' => '2.0.6',
        },
        'networks' => {},
      }
    end

    before do
      Models::VariableSet.make(deployment: deployment)
      deployment.add_cloud_config(cloud_config)
      release = Models::Release.make(name: 'bosh-release')
      release_version = Models::ReleaseVersion.make(version: '0.1-dev', release: release)
      template1 = Models::Template.make(name: 'foobar', release: release)
      release_version.add_template(template1)
      allow(instance).to receive(:active_vm).and_return(vm_model)

      allow(Config).to receive(:event_log).and_call_original
      allow(AgentClient).to receive(:with_agent_id).and_return(agent_client)
      instance_spec = DeploymentPlan::InstanceSpec.new(spec, deployment_plan_instance, variables_interpolator)
      allow(DeploymentPlan::InstanceSpec).to receive(:create_from_instance_plan).and_return(instance_spec)
    end

    describe 'perform' do
      it 'should stop the instance' do
        job = Jobs::StopInstance.new(instance.id, {})
        expect(instance.state).to eq 'started'

        job.perform

        pre_stop_env = {'env' => {
          'BOSH_VM_NEXT_STATE' => 'keep',
          'BOSH_INSTANCE_NEXT_STATE' => 'keep',
          'BOSH_DEPLOYMENT_NEXT_STATE' => 'keep',
        }}

        expect(agent_client).to have_received(:run_script).with('pre-stop', pre_stop_env)
        expect(agent_client).to have_received(:drain).with('shutdown', anything)
        expect(agent_client).to have_received(:stop)
        expect(agent_client).to have_received(:run_script).with('post-stop', {})
        expect(instance.state).to eq 'stopped'
      end
    end
  end
end
