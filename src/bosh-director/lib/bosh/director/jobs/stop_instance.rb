module Bosh::Director
  module Jobs
    class StopInstance < BaseJob
      # include LockHelper

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
        deployment_plan = DeploymentPlan::PlannerFactory.create(Config.logger)
                                                        .create_from_model(instance_model.deployment)
        deployment_plan.releases.each(&:bind_model)

        instance_group = deployment_plan.instance_groups.find { |ig| ig.name == instance_model.job }

        instance_group.jobs.each(&:bind_models)

        instance_plan = construct_instance_plan(instance_model, deployment_plan, instance_group, @options)

        event_log = Config.event_log
        event_log_stage = event_log.begin_stage("Updating instance #{instance_group.name}")
        event_log_stage.advance_and_track(instance_plan.instance.model.to_s) do
          Stopper.new(instance_plan, instance_model.state, Config, Config.logger).stop(:keep_vm)
        end
      end

      private

      def construct_instance_plan(instance_model, deployment_plan, instance_group, options)
        desired_instance = DeploymentPlan::DesiredInstance.new(instance_group, deployment_plan)
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
