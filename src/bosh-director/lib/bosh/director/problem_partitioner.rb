module Bosh::Director
  class ProblemPartition

    attr_reader :instance_group_name
    attr_reader :problems
    attr_reader :serial

    def initialize(problems, instance_group_name, serial)
      @instance_group_name = instance_group_name
      @problems = problems
      @serial = serial
    end

    def ==(other)
      problems == other.problems &&
        instance_group_name == other.instance_group_name &&
        serial == other.serial
    end
  end

  class ProblemPartitioner
    def partition_by_instance_group(deployment, problems)
      deployment_config = DeploymentConfig.new(YAML.safe_load(deployment.manifest), nil)
      deployment_config.instance_groups.map do |instance_group|
        ProblemPartition.new(
          problems.select { |problem| get_instance_group_name(problem.resource_id) == instance_group.name },
          instance_group.name,
          instance_group.serial,
        )
      end
    end

    private

    def get_instance_group_name(instance_id)
      instance = Models::Instance.where(id: instance_id).first
      instance.job
    end
  end
end
