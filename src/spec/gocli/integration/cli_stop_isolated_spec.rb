require_relative '../spec_helper'

describe 'stop command', type: :integration do
  with_reset_sandbox_before_each

  let(:manifest_hash) do
    manifest_hash = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups
    manifest_hash['instance_groups'] << {
      'name' => 'another-job',
      'jobs' => [
        {
          'name' => 'foobar',
          'release' => 'bosh-release',
          'properties' => {
            'test_property' => 'first_deploy',
          },
        },
      ],
      'vm_type' => 'a',
      'instances' => 1,
      'networks' => [{ 'name' => 'a' }],
      'stemcell' => 'default',
    }
    manifest_hash
  end

  def curl_with_redirect(url, options = {})
    curl_output = bosh_runner.run("curl #{url}", { json: true }.merge(options))
    task_id = JSON.parse(parse_blocks(curl_output)[0])['id']
    bosh_runner.run("task #{task_id}")
  end

  context 'with a job name' do
    before do
      deploy_from_scratch(manifest_hash: manifest_hash, cloud_config_hash: Bosh::Spec::NewDeployments.simple_cloud_config)
    end

    xcontext 'with an index or id' do
      it 'stops the indexed job' do
        expect do
          output = bosh_runner.run('stop foobar/0', deployment_name: 'simple')
          expect(output).to match /Updating instance foobar: foobar.* \(0\)/
        end.to change { vm_states }
          .from(
            'another-job/0' => 'running',
            'foobar/0' => 'running',
            'foobar/1' => 'running',
            'foobar/2' => 'running',
          )
          .to(
            'another-job/0' => 'running',
            'foobar/0' => 'stopped',
            'foobar/1' => 'running',
            'foobar/2' => 'running',
          )

        instance_before_with_index_1 = director.instances.find { |instance| instance.index == '1' }
        instance_uuid = instance_before_with_index_1.id

        expect do
          output = bosh_runner.run("stop foobar/#{instance_uuid}", deployment_name: 'simple')
          expect(output).to match /Updating instance foobar: foobar\/#{instance_uuid} \(\d\)/
        end.to change { vm_states }
          .from(
            'another-job/0' => 'running',
            'foobar/0' => 'stopped',
            'foobar/1' => 'running',
            'foobar/2' => 'running',
          )
          .to(
            'another-job/0' => 'running',
            'foobar/0' => 'stopped',
            'foobar/1' => 'stopped',
            'foobar/2' => 'running',
          )

        output = bosh_runner.run('events', json: true)
        events = scrub_event_time(scrub_random_cids(scrub_random_ids(table(output))))

        # these events will be different, do we still have an "update" "deployment" event?
        expect(events).to include(
          { 'id' => /[0-9]{1,3} <- [0-9]{1,3}/, 'time' => 'xxx xxx xx xx:xx:xx UTC xxxx', 'user' => 'test', 'action' => 'update', 'object_type' => 'deployment', 'task_id' => /[0-9]{1,3}/, 'object_name' => 'simple', 'deployment' => 'simple', 'instance' => '', 'context' => "after:\n  releases:\n  - bosh-release/0+dev.1\n  stemcells:\n  - ubuntu-stemcell/1\nbefore:\n  releases:\n  - bosh-release/0+dev.1\n  stemcells:\n  - ubuntu-stemcell/1", 'error' => '' },
          { 'id' => /[0-9]{1,3} <- [0-9]{1,3}/, 'time' => 'xxx xxx xx xx:xx:xx UTC xxxx', 'user' => 'test', 'action' => 'stop', 'object_type' => 'instance', 'task_id' => /[0-9]{1,3}/, 'object_name' => 'foobar/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', 'deployment' => 'simple', 'instance' => 'foobar/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', 'context' => '', 'error' => '' },
          { 'id' => /[0-9]{1,3}/, 'time' => 'xxx xxx xx xx:xx:xx UTC xxxx', 'user' => 'test', 'action' => 'stop', 'object_type' => 'instance', 'task_id' => /[0-9]{1,3}/, 'object_name' => 'foobar/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', 'deployment' => 'simple', 'instance' => 'foobar/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', 'context' => '', 'error' => '' },
          { 'id' => /[0-9]{1,3}/, 'time' => 'xxx xxx xx xx:xx:xx UTC xxxx', 'user' => 'test', 'action' => 'update', 'object_type' => 'deployment', 'task_id' => /[0-9]{1,3}/, 'object_name' => 'simple', 'deployment' => 'simple', 'instance' => '', 'context' => '', 'error' => '' },
        )
      end
    end

    context 'when there are unrelated instances that are not converged' do
      let(:late_fail_manifest) do
        manifest_hash = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups
        manifest_hash['instance_groups'] << {
          'name' => 'another-job',
          'jobs' => [
            {
              'name' => 'foobar',
              'release' => 'bosh-release',
              'properties' => {
                'test_property' => 'second_deploy',
              },
            },
          ],
          'vm_type' => 'a',
          'instances' => 1,
          'networks' => [{ 'name' => 'a' }],
          'stemcell' => 'default',
        }
        manifest_hash['instance_groups'] << {
          'name' => 'the-broken-job',
          'jobs' => [
            {
              'name' => 'job_with_post_start_script',
              'release' => 'bosh-release',
              'properties' => {
                'exit_code' => 1,
              },
            },
          ],
          'vm_type' => 'a',
          'instances' => 1,
          'networks' => [{ 'name' => 'a' }],
          'stemcell' => 'default',
        }

        manifest_hash
      end

      before do
        deploy(manifest_hash: late_fail_manifest, failure_expected: true)
      end

      it 'only stops the indexed job' do
        output = curl_with_redirect('-X POST /deployments/simple/jobs/foobar/0/actions/stop')
        expect(output).not_to include('another-job')
        expect(output).to include('foobar')
      end
    end

    xcontext 'without an index or id' do
      it 'stops all instances of the job' do
        expect do
          output = bosh_runner.run('stop foobar', deployment_name: 'simple')
          expect(output).to match /Updating instance foobar: foobar\/.* \(0\)/
          expect(output).to match /Updating instance foobar: foobar\/.* \(1\)/
          expect(output).to match /Updating instance foobar: foobar\/.* \(2\)/
        end.to change { vm_states }
          .from(
            'another-job/0' => 'running',
            'foobar/0' => 'running',
            'foobar/1' => 'running',
            'foobar/2' => 'running',
          )
          .to(
            'another-job/0' => 'running',
            'foobar/0' => 'stopped',
            'foobar/1' => 'stopped',
            'foobar/2' => 'stopped',
          )
      end
    end

    xcontext 'given the --hard flag' do
      it 'deletes the VM(s)' do
        expect do
          output = bosh_runner.run('stop foobar/0 --hard', deployment_name: 'simple')
          expect(output).to match /Updating instance foobar: foobar\/.* \(0\)/
        end.to change { director.vms.count }.by(-1)
      end
    end
  end

  xcontext 'without a job name' do
    before do
      deploy_from_scratch(manifest_hash: manifest_hash, cloud_config_hash: Bosh::Spec::NewDeployments.simple_cloud_config)
    end

    it 'stops all jobs in the deployment' do
      expect do
        output = bosh_runner.run('stop', deployment_name: 'simple')
        expect(output).to match /Updating instance foobar: foobar\/.* \(0\)/
        expect(output).to match /Updating instance foobar: foobar\/.* \(1\)/
        expect(output).to match /Updating instance foobar: foobar\/.* \(2\)/
        expect(output).to match /Updating instance another-job: another-job\/.* \(0\)/
      end.to change { vm_states }
        .from(
          'another-job/0' => 'running',
          'foobar/0' => 'running',
          'foobar/1' => 'running',
          'foobar/2' => 'running',
        )
        .to(
          'another-job/0' => 'stopped',
          'foobar/0' => 'stopped',
          'foobar/1' => 'stopped',
          'foobar/2' => 'stopped',
        )
    end
  end

  xdescribe 'hard-stopping a job with persistent disk, followed by a re-deploy' do
    before do
      manifest_hash['instance_groups'].first['persistent_disk'] = 1024
      deploy_from_scratch(manifest_hash: manifest_hash, cloud_config_hash: Bosh::Spec::NewDeployments.simple_cloud_config)
    end

    it 'is successful (regression: #108398600) ' do
      bosh_runner.run('stop foobar --hard', deployment_name: 'simple')
      expect(vm_states).to eq('another-job/0' => 'running')
      expect do
        deploy_from_scratch(manifest_hash: manifest_hash, cloud_config_hash: Bosh::Spec::NewDeployments.simple_cloud_config)
      end.to_not raise_error
      expect(vm_states).to eq('another-job/0' => 'running')
    end
  end

  def vm_states
    director.instances.each_with_object({}) do |instance, result|
      result["#{instance.instance_group_name}/#{instance.index}"] = instance.last_known_state unless instance.last_known_state.empty?
    end
  end
end
