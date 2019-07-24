module Bosh::Director
  module Jobs
    class InstanceLifecycle < BaseJob
      include LockHelper

      def initialize(deployment_name, instance_id, options = {})
        @deployment_name = deployment_name
        @instance_id = instance_id
        @options = options
        @logger = Config.logger
      end

      private

      def add_event(action, instance_model, parent_id = nil, error = nil)
        instance_name = instance_model.name
        deployment_name = instance_model.deployment.name

        event = Config.current_job.event_manager.create_event(
          parent_id: parent_id,
          user: Config.current_job.username,
          action: action,
          object_type: 'instance',
          object_name: instance_name,
          task: Config.current_job.task_id,
          deployment: deployment_name,
          instance: instance_name,
          error: error,
        )
        event.id
      end
    end
  end
end
