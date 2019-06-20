require 'spec_helper'
require 'bosh/director/starter'

module Bosh::Director
  describe Starter do
    subject(:starter) { described_class }
    let(:vm_model) { Models::Vm.make(cid: 'vm-cid', instance_id: instance_model.id) }
    let(:instance_model) { Models::Instance.make(spec: spec) }
    let(:agent_client) { instance_double('Bosh::Director::AgentClient') }
    let(:skip_drain) { false }
    let(:deployment_model) { instance_double(Bosh::Director::Models::Deployment, name: 'fake-deployment') }
    let(:variables_interpolator) { instance_double(Bosh::Director::ConfigServer::VariablesInterpolator) }
    let(:current_job_state) { 'running' }
    let(:desired_instance) { DeploymentPlan::DesiredInstance.new(job) }
    let(:update_watch_time) { '1000-2000' }
    let(:update_config) do
      DeploymentPlan::UpdateConfig.new(
        'canaries' => 1,
        'max_in_flight' => 1,
        'canary_watch_time' => '1000-2000',
        'update_watch_time' => update_watch_time,
      )
    end

    let(:job) do
      instance_double(
        DeploymentPlan::InstanceGroup,
        name: 'fake-job-name',
        default_network: {},
      )
    end

    let(:instance) do
      instance_double(
        DeploymentPlan::Instance,
        instance_group_name: job.name,
        model: instance_model,
        availability_zone: DeploymentPlan::AvailabilityZone.new('az', {}),
        index: 0,
        uuid: SecureRandom.uuid,
        rendered_templates_archive: nil,
        configuration_hash: { 'fake-spec' => true },
        template_hashes: [],
        current_job_state: current_job_state,
        deployment_model: deployment_model,
      )
    end

    let(:instance_plan) do
      DeploymentPlan::InstancePlan.new(
        existing_instance: instance_model,
        instance: instance,
        desired_instance: desired_instance,
        skip_drain: skip_drain,
        variables_interpolator: variables_interpolator,
      )
    end

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
      fake_app
      allow(instance).to receive(:current_networks)
      instance_spec = DeploymentPlan::InstanceSpec.new(spec, instance, variables_interpolator)
      allow(instance_plan).to receive(:spec).and_return(instance_spec)

      instance_model.active_vm = vm_model
      allow(AgentClient).to receive(:with_agent_id).with(instance_model.agent_id, instance_model.name).and_return(agent_client)
    end

    describe '#start' do
      before do
        allow(agent_client).to receive(:run_script).with('pre-start', {})
        allow(agent_client).to receive(:start)
        allow(agent_client).to receive(:get_state).and_return('job_state' => current_job_state)
        allow(agent_client).to receive(:run_script).with('post-start', {})
      end

      context 'when updating an instance' do
        it 'waits for desired state and runs post-start' do
          expect(agent_client).to receive(:run_script).with('pre-start', {}).ordered
          expect(agent_client).to receive(:start).ordered
          expect(agent_client).to receive(:get_state).ordered
          expect(agent_client).to receive(:run_script).with('post-start', {}).ordered
          starter.start(instance, agent_client, update_config, false, true)
        end
      end

      context 'when starting a stopped instance' do
        it 'waits for desired state and runs post-start' do
          expect(agent_client).to receive(:run_script).with('pre-start', {}).ordered
          expect(agent_client).to receive(:start).ordered
          expect(agent_client).not_to receive(:get_state)
          expect(agent_client).not_to receive(:run_script).with('post-start', {})
          starter.start(instance, agent_client, update_config)
        end
      end

      context 'when post start fails' do
        let(:current_job_state) { 'unmonitored' }

        it 'throws an exception' do
          expect do
            starter.start(instance, agent_client, update_config, false, true)
          end.to raise_exception(Bosh::Director::AgentJobNotRunning)
        end
      end
    end
  end
end
