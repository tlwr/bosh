require_relative '../../spec_helper'

describe 'dynamic networks', type: :integration do
  with_reset_sandbox_before_each

  let(:runner) { bosh_runner_in_work_dir(ClientSandbox.test_release_dir) }

  before do
    create_and_upload_test_release
    upload_stemcell
  end

  let(:cloud_config_hash) do
    cloud_config_hash = Bosh::Spec::Deployments.simple_cloud_config
    cloud_config_hash['networks'] = [{
      'name' => 'a',
      'type' => 'dynamic',
    }]
    cloud_config_hash
  end

  let(:simple_manifest) do
    manifest_hash = Bosh::Spec::Deployments.simple_manifest_with_instance_groups
    manifest_hash['instance_groups'].first['instances'] = 1

    manifest_hash
  end

  it 'sends the IaaS the previously-assigned dynamic IP on a subsequent recreate', no_create_swap_delete: true do
    upload_cloud_config(cloud_config_hash: cloud_config_hash)
    deploy_simple_manifest(manifest_hash: simple_manifest)

    original_instances = director.instances
    expect(original_instances.size).to eq(1)
    original_ip = original_instances.first.ips[0]
    expect(original_ip).to be_truthy

    invocations = current_sandbox.cpi.invocations
    expect(invocations[20].method_name).to eq('create_vm')
    expect(invocations[20].inputs['networks']['a']['ip']).to be_nil

    runner.run('recreate foobar/0', deployment_name: 'simple')

    invocations = current_sandbox.cpi.invocations
    expect(invocations[28].method_name).to eq('create_vm')
    expect(invocations[28].inputs['networks']['a']['ip']).to match(original_ip)

    new_instances = director.instances
    expect(new_instances.size).to eq(1)
  end
end
