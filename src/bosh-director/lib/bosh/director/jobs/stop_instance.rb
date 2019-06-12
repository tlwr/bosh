module Bosh::Director
  module Jobs
    class StopInstance < BaseJob
      # include LockHelper  # do we need a deployment lock? Probably...

      @queue = :normal

      def self.job_type
        :stop_instance
      end

      def initialize(instance_id, options = {})
        @instance_id = instance_id
        @options = options
      end

      def perform
        instance_model = Models::Instance.find(id: @instance_id)
        # return early if already stopped or detached
        deployment_plan = DeploymentPlan::PlannerFactory.create(Config.logger)
                                                        .create_from_model(instance_model.deployment)
        deployment_plan.releases.each(&:bind_model)

        instance_group = deployment_plan.instance_groups.find { |ig| ig.name == instance_model.job }

        instance_group.jobs.each(&:bind_models)

        instance_plan = construct_instance_plan(instance_model, deployment_plan, instance_group, @options)
        desired_state = @options['hard'] ? 'detached' : 'stopped'

        event_log = Config.event_log
        event_log_stage = event_log.begin_stage("Updating instance #{instance_group.name}")
        event_log_stage.advance_and_track(instance_plan.instance.model.to_s) do
          Stopper.new(instance_plan, desired_state, Config, Config.logger).stop(:keep_vm)
          Api::SnapshotManager.take_snapshot(instance_model, clean: true)

          detach_instance(instance_model) if @options['hard']

          # convergence
          DiskManager.new(Config.logger).update_persistent_disk(instance_plan) unless @options['hard']
          instance_model.update(state: desired_state)
        end
      end

      private

      def detach_instance(instance_model)
        instance_report = DeploymentPlan::Stages::Report.new.tap { |r| r.vm = instance_model.active_vm }
        DeploymentPlan::Steps::UnmountInstanceDisksStep.new(instance_model).perform(instance_report)
        DeploymentPlan::Steps::DeleteVmStep.new(true, false, Config.enable_virtual_delete_vms).perform(instance_report)
      end

      def construct_instance_plan(instance_model, deployment_plan, instance_group, options)
        desired_instance = DeploymentPlan::DesiredInstance.new(instance_group, deployment_plan) # index?
        variables_interpolator = ConfigServer::VariablesInterpolator.new

        instance_repository = DeploymentPlan::InstanceRepository.new(Config.logger, variables_interpolator)
        instance = instance_repository.fetch_existing(
          instance_model,
          instance_model.state,
          instance_group,
          instance_model.index,
          deployment_plan,
        )

        network_plans = instance.existing_network_reservations.map do |reservation|
          DeploymentPlan::NetworkPlanner::Plan.new(reservation: reservation, existing: true)
        end

        DeploymentPlan::InstancePlan.new(
          existing_instance: instance_model,
          desired_instance: desired_instance,
          instance: instance,
          variables_interpolator: variables_interpolator,
          network_plans: network_plans,
          skip_drain: options['skip_drain'],
        )
      end
    end
  end
end
