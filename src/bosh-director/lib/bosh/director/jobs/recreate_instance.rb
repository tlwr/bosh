module Bosh::Director
  module Jobs
    class RecreateInstance < BaseJob
      include LockHelper

      @queue = :normal

      def self.job_type
        :start_instance
      end

      def initialize(deployment_name, instance_id, options = {})
        @deployment_name = deployment_name
        @instance_id = instance_id
        @options = options
        @logger = Config.logger
      end

      def perform
        with_deployment_lock(@deployment_name) do
          stop
          recreate
          start
        end
      end

      private

      def recreate
        instance_model = Models::Instance.find(id: @instance_id)
        raise InstanceNotFound if instance_model.nil?
        raise InstanceNotFound if instance_model.deployment.name != @deployment_name

        deployment_plan = DeploymentPlan::PlannerFactory.create(@logger)
                            .create_from_model(instance_model.deployment)
        deployment_plan.releases.each(&:bind_model)

        instance_group = deployment_plan.instance_groups.find { |ig| ig.name == instance_model.job }
        if instance_group.errand?
          raise InstanceGroupInvalidLifecycleError,
                'Start can not be run on instances of type errand. Try the bosh run-errand command.'
        end

        instance_group.jobs.each(&:bind_models)

        instance_plan = construct_instance_plan(instance_model, deployment_plan, instance_group)

        stop
        delete_vm
        create_vm
        start
      end

      def construct_instance_plan(instance_model, deployment_plan, instance_group)
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

      def stop

      end

      def delete_vm

      end

      def create_vm

      end

      def start

      end

    end
  end
end