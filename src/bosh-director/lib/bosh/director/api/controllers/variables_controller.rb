require 'bosh/director/api/controllers/base_controller'

module Bosh::Director
  module Api::Controllers
    class VariablesController < BaseController
      register Bosh::Director::Api::Extensions::DeploymentsSecurity

      def initialize(config)
        super(config)
        @deployment_manager = Api::DeploymentManager.new
        @problem_manager = Api::ProblemManager.new
        @property_manager = Api::PropertyManager.new
        @instance_manager = Api::InstanceManager.new
        @deployments_repo = DeploymentPlan::DeploymentRepo.new
        @instance_ignore_manager = Api::InstanceIgnoreManager.new
      end

      get '/', authorization: :create_deployment do
        return status(422) unless params['name']

        all_deployments = Models::Deployment.all

        my_deployments = all_deployments.select do |deployment|
          @permission_authorizer.is_granted?(deployment, :read, token_scopes) &&
            deployment.last_successful_variable_set&.find_variable_by_name(params['name'])
        end

        result = my_deployments.map do |deployment|
          response = {
            'name' => deployment.name,
            'version' => deployment.last_successful_variable_set.id, # need to get the version here somehow??
          }
          response
        end

        json_encode(result)
      end
    end
  end
end
