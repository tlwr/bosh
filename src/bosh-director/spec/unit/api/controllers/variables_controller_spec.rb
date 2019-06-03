require 'spec_helper'
require 'rack/test'

module Bosh::Director
  module Api
    describe Controllers::VariablesController do
      include IpUtil
      include Rack::Test::Methods

      subject(:app) { linted_rack_app(described_class.new(config)) }

      let(:config) do
        config = Config.load_hash(SpecHelper.spec_get_director_config)
        identity_provider = Support::TestIdentityProvider.new(config.get_uuid_provider)
        allow(config).to receive(:identity_provider).and_return(identity_provider)
        config
      end

      describe '/variables' do
        let(:deployment_manifest) { { 'name' => 'test_deployment' } }
        let!(:deployment) { Models::Deployment.make(name: 'test_deployment', manifest: deployment_manifest.to_yaml) }
        let!(:variable_set) { Models::VariableSet.make(id: 1, deployment: deployment, deployed_successfully: true) }

        before do
          basic_authorize 'admin', 'admin'
        end

        it 'returns an empty array if there are no matching deployments' do
          get '/?name=foo'
          expect(last_response.status).to eq(200)
          vars = JSON.parse(last_response.body)
          expect(vars).to be_empty
        end

        context 'when a deployment has variables' do
          let(:deployment_manifest) do
            {
              'name' => 'test_deployment',
              'variables' => [
                { 'name' => 'var_name_1' },
                { 'name' => 'var_name_2' },
              ],
            }
          end

          before do
            Models::Variable.make(
              id: 1,
              variable_id: 'var_id_1',
              variable_name: '/Test Director/test_deployment/var_name_1',
              variable_set_id: variable_set.id,
            )
            Models::Variable.make(
              id: 2,
              variable_id: 'var_id_2',
              variable_name: '/Test Director/test_deployment/var_name_2',
              variable_set_id: variable_set.id,
            )
          end

          it 'returns a unique list of variable ids and names' do
            get '/?name=%2FTest%20Director%2Ftest_deployment%2Fvar_name_1'
            expect(last_response.status).to eq(200)
            vars = JSON.parse(last_response.body)
            expect(vars).to match_array(
              [
                { 'id' => 'var_id_1', 'name' => '/Test Director/test_deployment/var_name_1' },
                { 'id' => 'var_id_2', 'name' => '/Test Director/test_deployment/var_name_2' },
              ],
            )
          end
        end
      end
    end
  end
end
