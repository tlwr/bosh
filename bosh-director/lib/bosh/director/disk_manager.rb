module Bosh::Director
  class DiskManager

    def initialize(cloud, logger)
      @cloud = cloud
      @logger = logger
    end

    def update_persistent_disk(instance_plan, vm_recreator)
      instance = instance_plan.instance
      job = instance_plan.desired_instance.job

      check_persistent_disk(instance)

      disk = nil
      return unless instance_plan.persistent_disk_changed?

      old_disk = instance.model.persistent_disk

      if job.persistent_disk_type && job.persistent_disk_type.disk_size > 0
        disk = create_and_attach_disk(instance_plan, vm_recreator)
        mount_and_migrate_disk(instance, disk, old_disk)
      end

      instance.model.db.transaction do
        old_disk.update(:active => false) if old_disk
        disk.update(:active => true) if disk
      end

      delete_mounted_persistent_disk(instance, old_disk) if old_disk
    end

    def attach_disks_for(instance)
      disk_cid = instance.model.persistent_disk_cid
      return @logger.info('Skipping disk attaching') if disk_cid.nil?
      vm_model = instance.vm.model
      begin
        @cloud.attach_disk(vm_model.cid, disk_cid)
        AgentClient.with_vm(vm_model).mount_disk(disk_cid)
      rescue => e
        @logger.warn("Failed to attach disk to new VM: #{e.inspect}")
        raise e
      end
    end

    def delete_persistent_disks(instance_model)
      instance_model.persistent_disks.each do |disk|
        orphan_disk(disk)
      end
    end

    def orphan_disk(disk)
      disk.db.transaction do
        orphan_disk = Models::OrphanDisk.create(
          disk_cid: disk.disk_cid,
          size: disk.size,
          availability_zone: disk.instance.availability_zone,
          deployment_name: disk.instance.deployment.name,
          instance_name: "#{disk.instance.job}/#{disk.instance.uuid}",
          cloud_properties: disk.cloud_properties
        )

        orphan_snapshots(disk.snapshots, orphan_disk)
        @logger.info("Orphaning disk: '#{disk.disk_cid}', " +
            "#{disk.active ? "active" : "inactive"}")

        disk.destroy
      end
    end

    def list_orphan_disks
      Models::OrphanDisk.all.map do |disk|
        {
          'disk_cid' => disk.disk_cid,
          'size' => disk.size || 'n/a',
          'availability_zone' => disk.availability_zone || 'n/a',
          'deployment_name' => disk.deployment_name,
          'instance_name' => disk.instance_name,
          'cloud_properties' => disk.cloud_properties.any? ? disk.cloud_properties : 'n/a',
          'orphaned_at' => disk.orphaned_at.to_s
        }
      end
    end

    def delete_orphan_disk(disk_cid)
      @logger.info("Deleting orphan disk: #{disk_cid}")
      orphan_disk = Bosh::Director::Models::OrphanDisk.where(disk_cid: disk_cid).first
      if orphan_disk
        begin
          @cloud.delete_disk(orphan_disk.disk_cid)
          orphan_disk.destroy
        rescue Bosh::Clouds::DiskNotFound
          @logger.debug("Disk not found in IaaS: #{orphan_disk.disk_cid}")
          orphan_disk.destroy
        end
      else
        @logger.debug("Disk not found: #{disk_cid}")
      end
    end

    def unmount_disk_for(instance_plan)
      disk = instance_plan.instance.model.persistent_disk
      return if disk.nil?
      unmount(instance_plan.instance, disk)
    end

    private

    def orphan_snapshots(snapshots, orphan_disk)
      snapshots.each do |snapshot|
        @logger.info("Orphaning snapshot: '#{snapshot.snapshot_cid}'")
        Models::OrphanSnapshot.create(
          orphan_disk: orphan_disk,
          snapshot_cid: snapshot.snapshot_cid,
          clean: snapshot.clean,
          created_at: snapshot.created_at
        )
        snapshot.delete
      end
    end

    def delete_mounted_persistent_disk(instance, disk)
      unmount(instance, disk)

      vm_cid = instance.model.vm.cid
      if vm_cid.nil?
        @logger.info('Skipping disk detaching, instance does not have VM')
        return
      end

      disk_cid = disk.disk_cid
      if disk_cid.nil?
        @logger.info('Skipping disk detaching, instance does not have a disk')
        return
      end

      begin
        @logger.info("Detaching disk #{disk_cid}")
        @cloud.detach_disk(vm_cid, disk_cid)
      rescue Bosh::Clouds::DiskNotAttached
        if disk.active
          raise CloudDiskNotAttached,
            "`#{instance}' VM should have persistent disk attached " +
              "but it doesn't (according to CPI)"
        end
      end

      orphan_disk(disk)
    end

    def unmount(instance, disk)
      disk_cid = disk.disk_cid
      if disk_cid.nil?
        @logger.info('Skipping disk unmounting, instance does not have a disk')
        return
      end

      if disks(instance).include?(disk_cid)
        @logger.info("Unmounting disk #{disk_cid}")
        agent(instance).unmount_disk(disk_cid)
      end
    end

    # Synchronizes persistent_disks with the agent.
    # (Currently assumes that we only have 1 persistent disk.)
    # @return [void]
    def check_persistent_disk(instance)
      return if instance.model.persistent_disks.empty?
      agent_disk_cid = disks(instance).first

      if agent_disk_cid != instance.model.persistent_disk_cid
        raise AgentDiskOutOfSync,
          "`#{instance}' has invalid disks: agent reports " +
            "`#{agent_disk_cid}' while director record shows " +
            "`#{instance.model.persistent_disk_cid}'"
      end

      instance.model.persistent_disks.each do |disk|
        unless disk.active
          @logger.warn("`#{instance}' has inactive disk #{disk.disk_cid}")
        end
      end
    end

    def disks(instance)
      agent(instance).list_disk
    end

    def agent(instance)
      AgentClient.with_vm(instance.vm.model)
    end

    def create_and_attach_disk(instance_plan, vm_recreator)
      instance = instance_plan.instance
      disk = create_disk(instance_plan)
      @cloud.attach_disk(instance.model.vm.cid, disk.disk_cid)
      return disk
    rescue Bosh::Clouds::NoDiskSpace => e
      if e.ok_to_retry
        @logger.warn('Retrying attach disk operation after persistent disk update failed')
        # Re-creating the vm may cause it to be re-created in a place with more storage
        unmount_disk_for(instance_plan)
        vm_recreator.recreate_vm(instance_plan, disk.disk_cid)
        begin
          @cloud.attach_disk(instance.model.vm.cid, disk.disk_cid)
        rescue
          orphan_disk(disk)
          raise
        end
      else
        orphan_disk(disk)
        raise
      end
      return disk
    end

    def mount_and_migrate_disk(instance, new_disk, old_disk)
      agent(instance).mount_disk(new_disk.disk_cid)
      agent(instance).migrate_disk(old_disk.disk_cid, new_disk.disk_cid) if old_disk
    rescue
      delete_mounted_persistent_disk(instance, new_disk)
      raise
    end

    def create_disk(instance_plan)
      job = instance_plan.desired_instance.job
      instance_model = instance_plan.instance.model

      disk_size = job.persistent_disk_type.disk_size
      cloud_properties = job.persistent_disk_type.cloud_properties

      disk_cid = @cloud.create_disk(disk_size, cloud_properties, instance_model.vm.cid)
      Models::PersistentDisk.create(
        disk_cid: disk_cid,
        active: false,
        instance_id: instance_model.id,
        size: disk_size,
        cloud_properties: cloud_properties,
      )
    end
  end
end
