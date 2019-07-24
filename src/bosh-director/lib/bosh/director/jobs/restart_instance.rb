module Bosh::Director
  module Jobs
    class RestartInstance < InstanceLifecycle
      @queue = :normal

      def self.job_type
        :restart_instance
      end

      def perform
        with_deployment_lock(@deployment_name) do
          instance_model = Models::Instance.find(id: @instance_id)
          raise InstanceNotFound if instance_model.nil?

          begin
            parent_event_id = add_event('restart', instance_model)

            Jobs::StopInstance.new(@deployment_name, @instance_id, @options).perform_without_lock
            Jobs::StartInstance.new(@deployment_name, @instance_id, @options).perform_without_lock
          rescue StandardError => e
            raise e
          ensure
            add_event('restart', instance_model, parent_event_id, e)
          end

          instance_model.name
        end
      end
    end
  end
end
