require 'spec_helper'

module Bosh::Director
  describe DeploymentPlan::InstanceNetworkReservations do
    let(:deployment_model) { Models::Deployment.make(name: 'foo-deployment') }
    let(:cloud_config) { Models::Config.make(:cloud_with_manifest_v2) }
    let(:runtime_config) { Models::Config.make(type: 'runtime') }
    let(:cloud_planner) { instance_double(DeploymentPlan::CloudPlanner) }
    let(:deployment) do
      deployment = DeploymentPlan::Planner.new(
        {name: 'foo-deployment', properties: {}},
        '',
        '',
        [cloud_config],
        runtime_config,
        deployment_model
      )
      deployment.cloud_planner = cloud_planner
      deployment
    end
    let(:network) do
      DeploymentPlan::ManualNetwork.parse(
        manual_network_spec,
        [
          BD::DeploymentPlan::AvailabilityZone.new('az-1', {}),
          BD::DeploymentPlan::AvailabilityZone.new('az-2', {}),
        ],
        logger,
      )
    end
    let(:manual_network_spec) do
      {
        'name' => 'fake-network',
        'subnets' => [
          {
            'range' => '192.168.0.0/24',
            'gateway' => '192.168.0.4',
          },
        ],
      }
    end
    let(:instance_model) { Models::Instance.make(deployment: deployment_model) }
    let!(:variable_set) { Models::VariableSet.make(deployment: deployment_model) }
    let(:ip_provider) do
      DeploymentPlan::IpProvider.new(DeploymentPlan::IpRepo.new(logger), { 'fake-network' => network }, logger)
    end
    before do
      allow(deployment).to receive(:ip_provider).and_return(ip_provider)
      allow(cloud_planner).to receive(:networks).and_return([network])
      allow(deployment).to receive(:network).with('fake-network').and_return(network)
      Bosh::Director::Config.current_job = Bosh::Director::Jobs::BaseJob.new
      Bosh::Director::Config.current_job.task_id = 'fake-task-id'
    end

    describe 'create_from_db' do
      context 'when there are IP addresses in db' do
        let(:ip1) { NetAddr::CIDR.create('192.168.0.1').to_i }
        let(:ip2) { NetAddr::CIDR.create('192.168.0.2').to_i }

        let(:ip_model1) do
          Models::IpAddress.make(address_str: ip1.to_s, instance: instance_model, network_name: 'fake-network')
        end

        let(:ip_model2) do
          Models::IpAddress.make(address_str: ip2.to_s, instance: instance_model, network_name: 'fake-network')
        end

        context 'when there is a last VM with IP addresses' do
          before do
            vm1 = BD::Models::Vm.make(instance: instance_model)
            vm2 = BD::Models::Vm.make(instance: instance_model)

            vm2.add_ip_address(ip_model1)
            vm2.add_ip_address(ip_model2)

            instance_model.add_vm vm1
            instance_model.add_vm vm2
          end

          it 'creates reservations from the last VM associated with an instance' do
            reservations = DeploymentPlan::InstanceNetworkReservations.create_from_db(instance_model, deployment, logger)
            expect(reservations.map(&:ip)).to eq([ip1, ip2])
          end
        end

        context 'when there are no IP addresses on the last VM or no VM' do
          before do
            instance_model.add_ip_address(ip_model1)
            instance_model.add_ip_address(ip_model2)
            allow(deployment).to receive(:network).with('fake-network').and_return(network)
          end

          it 'creates reservations based on IP addresses' do
            reservations = DeploymentPlan::InstanceNetworkReservations.create_from_db(instance_model, deployment, logger)
            expect(reservations.map(&:ip)).to eq([ip1, ip2])
          end
        end

        context 'when the network name saved in the database is of type Manual or Vip Global (ips in cloud config)' do
          before do
            instance_model.add_ip_address(ip_model1)
            allow(cloud_planner).to receive(:networks).and_return(network_with_subnets)
          end

          context 'if the IP is contained in that network range' do
            let(:network_with_subnets) { [DeploymentPlan::VipNetwork.parse(network_spec, [], logger)] }
            let(:network_spec) do
              {
                'name' => 'fake-network',
                'subnets' => [
                  { 'static' => ['192.168.0.1'] },
                ],
              }
            end

            it 'assigns that network to the reservation' do
              reservations = DeploymentPlan::InstanceNetworkReservations.create_from_db(instance_model, deployment, logger)
              expect(reservations.first.network).to eq(network_with_subnets.first)
            end
          end

          context 'if the IP is not contained in that network range' do
            let(:network_with_subnets) { [existing_network, new_network] }
            let(:existing_network) { DeploymentPlan::VipNetwork.parse(existing_network_spec, [], logger) }
            let(:new_network) { DeploymentPlan::VipNetwork.parse(new_network_spec, [], logger) }
            let(:existing_network_spec) do
              {
                'name' => 'fake-network',
                'subnets' => [
                  { 'static' => ['192.168.0.2'] },
                ],
              }
            end

            let(:new_network_spec) do
              {
                'name' => 'new-network',
                'subnets' => [
                  { 'static' => ['192.168.0.1'] },
                ],
              }
            end

            it 'assigns the closest matching network in the cloud config' do
              reservations = DeploymentPlan::InstanceNetworkReservations.create_from_db(instance_model, deployment, logger)
              expect(reservations.first.network).to eq(new_network)
            end
          end
        end

        context 'when the network name saved in the database is of type Vip Static (ips in instance groups)' do
          let(:network_with_subnets) { [] }
          let(:static_vip_network) { DeploymentPlan::VipNetwork.new('dummy', nil, [], nil) }

          before do
            instance_model.add_ip_address(ip_model1)
            allow(cloud_planner).to receive(:networks).and_return([static_vip_network])
            allow(deployment).to receive(:network).with('fake-network').and_return(static_vip_network)
          end

          it 'returns the network with matching name' do
            reservations = DeploymentPlan::InstanceNetworkReservations.create_from_db(instance_model, deployment, logger)
            expect(reservations.first.network).to eq(static_vip_network)
          end
        end

        context 'when there are no network subnets that contain the IP or matches by name' do
          let(:dummy_network) { DeploymentPlan::Network.new('fake-network', logger) }
          before do
            instance_model.add_ip_address(ip_model1)
            allow(cloud_planner).to receive(:networks).and_return([])
            allow(cloud_planner).to receive(:network).with('fake-network').and_return(nil)
            allow(DeploymentPlan::Network).to receive(:new).and_return(dummy_network)
          end

          it 'assigns a placeholder network' do
            reservations = DeploymentPlan::InstanceNetworkReservations.create_from_db(instance_model, deployment, logger)
            expect(reservations.first.network).to eq(dummy_network)
          end
        end
      end

      context 'when instance has dynamic networks in spec' do
        let(:instance_model) { Models::Instance.make(deployment: deployment_model, spec: instance_spec) }
        let(:instance_spec) do
          {
            'networks' => {
              'dynamic-network' => {
                'type' => 'dynamic',
                'ip' => '10.10.0.10'
              }
            }
          }
        end

        let(:dynamic_network) do
          DeploymentPlan::DynamicNetwork.new('dynamic-network', [], logger)
        end
        before do
          allow(deployment).to receive(:network).with('dynamic-network').and_return(dynamic_network)
        end

        it 'creates reservations for dynamic networks' do
          reservations = DeploymentPlan::InstanceNetworkReservations.create_from_db(instance_model, deployment, logger)
          expect(reservations.first).to_not be_nil
          expect(reservations.first.ip).to eq(NetAddr::CIDR.create('10.10.0.10').to_i)
        end
      end
    end
  end
end
