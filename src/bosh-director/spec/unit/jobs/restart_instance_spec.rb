require 'spec_helper'

module Bosh::Director
  describe Jobs::RestartInstance do
    include Support::FakeLocks

    let(:manifest) { Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups }
    let(:deployment) { Models::Deployment.make(name: 'simple', manifest: YAML.dump(manifest)) }

    let(:stop_instance_job) { instance_double(Jobs::StopInstance, perform_without_lock: instance_model.name) }
    let(:start_instance_job) { instance_double(Jobs::StartInstance, perform_without_lock: instance_model.name) }

    let(:event_manager) { Bosh::Director::Api::EventManager.new(true) }

    let(:instance_model) do
      Models::Instance.make(
        deployment: deployment,
        job: 'foobar',
        uuid: 'test-uuid',
        index: '1',
        state: 'started',
      )
    end

    before do
      fake_locks

      allow(Config).to receive_message_chain(:current_job, :event_manager).and_return(event_manager)
      allow(Config).to receive_message_chain(:current_job, :username).and_return('user')
      allow(Config).to receive_message_chain(:current_job, :task_id).and_return('5')

      allow(Jobs::StopInstance).to receive(:new).and_return(stop_instance_job)
      allow(Jobs::StartInstance).to receive(:new).and_return(start_instance_job)
    end

    describe 'DelayedJob job class expectations' do
      let(:job_type) { :restart_instance }
      let(:queue) { :normal }
      it_behaves_like 'a DJ job'
    end

    describe 'perform' do
      it 'should restart the instance' do
        job = Jobs::RestartInstance.new(deployment.name, instance_model.id, {})
        result_msg = job.perform

        expect(Jobs::StopInstance).to have_received(:new).with(deployment.name, instance_model.id, {})
        expect(stop_instance_job).to have_received(:perform_without_lock)
        expect(Jobs::StartInstance).to have_received(:new).with(deployment.name, instance_model.id, {})
        expect(start_instance_job).to have_received(:perform_without_lock)
        expect(result_msg).to eq 'foobar/test-uuid'
      end

      it 'respects skip_drain option' do
        job = Jobs::RestartInstance.new(deployment.name, instance_model.id, skip_drain: true)
        job.perform

        expect(Jobs::StopInstance).to have_received(:new).with(deployment.name, instance_model.id, skip_drain: true)
        expect(stop_instance_job).to have_received(:perform_without_lock)
        expect(Jobs::StartInstance).to have_received(:new).with(deployment.name, instance_model.id, an_instance_of(Hash))
        expect(start_instance_job).to have_received(:perform_without_lock)
      end

      it 'obtains a deployment lock' do
        job = Jobs::RestartInstance.new(deployment.name, instance_model.id, {})
        expect(job).to receive(:with_deployment_lock).with('simple').and_yield
        job.perform
      end

      it 'creates a restart event' do
        job = Jobs::RestartInstance.new(deployment.name, instance_model.id, {})
        expect do
          job.perform
        end.to change { Models::Event.count }.by(2)

        begin_event = Models::Event.first
        expect(begin_event.action).to eq('restart')
        expect(begin_event.parent_id).to be_nil

        end_event = Models::Event.last
        expect(end_event.action).to eq('restart')
        expect(end_event.parent_id).to eq(begin_event.id)
      end

      context 'when starting or stopping an instance fails' do
        let(:expected_error) { 'boom' }

        before do
          allow(stop_instance_job).to receive(:perform_without_lock).and_raise
        end

        it 'raises the error' do
          job = Jobs::RestartInstance.new(deployment.name, instance_model.id, {})
          expect do
            job.perform
          end.to raise_error
        end

        it 'still creates the corresponding restart events' do
          job = Jobs::RestartInstance.new(deployment.name, instance_model.id, {})
          expect do
            expect do
              job.perform
            end.to raise_error
          end.to change { Models::Event.count }.by(2)

          begin_event = Models::Event.first
          expect(begin_event.action).to eq('restart')
          expect(begin_event.parent_id).to be_nil

          end_event = Models::Event.last
          expect(end_event.action).to eq('restart')
          expect(end_event.parent_id).to eq(begin_event.id)
          expect(end_event.error).to_not be_nil
        end
      end
    end
  end
end
