module Bosh::Director
  module Jobs
    class RestartInstance < BaseJob
      include LockHelper

      @queue = :normal

      def self.job_type
        :restart_instance
      end

      def initialize(deployment_name, instance_id, options = {})
        @deployment_name = deployment_name
        @instance_id = instance_id
        @options = options
        @logger = Config.logger
      end

      def perform
        with_deployment_lock(@deployment_name) do
          restart
        end
      end

      def restart
        instance_model = Models::Instance.find(id: @instance_id)
        raise InstanceNotFound if instance_model.nil?

        deployment_plan = DeploymentPlan::PlannerFactory.create(@logger)
                            .create_from_model(instance_model.deployment)
        deployment_plan.releases.each(&:bind_model)

        instance_group = deployment_plan.instance_groups.find { |ig| ig.name == instance_model.job }
        instance_group.jobs.each(&:bind_models)

        instance_plan = construct_instance_plan(instance_model, deployment_plan, instance_group, @options)

        event_log = Config.event_log

        if instance_model.stopped? || instance_model.detached?
          event_log.log_entry("Instance #{instance_model.job} already stopped")
        else
          stopper = Jobs::StopInstance.new(@deployment_name, @instance_id, @options)
          event_log_stage = event_log.begin_stage("Stopping instance #{instance_model.job}")
          event_log_stage.advance_and_track(instance_plan.instance.model.to_s) do
            stopper.stop
          end
        end

        starter = Jobs::StartInstance.new(@deployment_name, @instance_id, @options)
        event_log_stage = event_log.begin_stage("Starting instance #{instance_model.job}")
        event_log_stage.advance_and_track(instance_plan.instance.model.to_s) do
          starter.start
        end
      end

      private

      # TODO: this was copied from start_instance, probably doesn't make a lot of sense ATM
      def construct_instance_plan(instance_model, deployment_plan, instance_group, options)
        desired_instance = DeploymentPlan::DesiredInstance.new(
          instance_group,
          deployment_plan,
          nil,
          instance_model.index,
          'started',
        )

        state_migrator = DeploymentPlan::AgentStateMigrator.new(@logger)
        existing_instance_state = instance_model.vm_cid ? state_migrator.get_state(instance_model) : {}

        variables_interpolator = ConfigServer::VariablesInterpolator.new

        instance_repository = DeploymentPlan::InstanceRepository.new(@logger, variables_interpolator)
        instance = instance_repository.build_instance_from_model(
          instance_model,
          existing_instance_state,
          desired_instance.state,
          desired_instance.deployment,
        )

        DeploymentPlan::InstancePlanFromDB.new(
          existing_instance: instance_model,
          desired_instance: desired_instance,
          instance: instance,
          variables_interpolator: variables_interpolator,
          tags: instance.deployment_model.tags,
          link_provider_intents: deployment_plan.link_provider_intents,
        )
      end
    end
  end
end
