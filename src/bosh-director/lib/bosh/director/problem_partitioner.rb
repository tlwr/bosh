module Bosh::Director
  class ProblemPartition

    attr_reader :instance_group_name
    attr_reader :problems
    attr_reader :serial
    attr_reader :max_in_flight

    def initialize(problems, instance_group_name, serial, max_in_flight)
      @instance_group_name = instance_group_name
      @problems = problems
      @serial = serial
      @max_in_flight = max_in_flight
    end

    def ==(other)
      problems == other.problems &&
        instance_group_name == other.instance_group_name &&
        serial == other.serial &&
        max_in_flight == other.max_in_flight
    end
  end

  class ProblemPartitioner
    def partition(deployment, problems)
      problem_partitions = problem_partitions_by_instance_group(deployment, problems)
      partition_problems_by_serial(problem_partitions)
    end

    private

    def problem_partitions_by_instance_group(deployment, problems)
      deployment_config = DeploymentConfig.new(YAML.safe_load(deployment.manifest), nil)
      deployment_config.instance_groups.map do |instance_group|
        ProblemPartition.new(
          problems.select { |problem| get_instance_group_name(problem.resource_id) == instance_group.name },
          instance_group.name,
          instance_group.serial,
          instance_group.max_in_flight,
        )
      end
    end

    def partition_problems_by_serial(partitioned_problems)
      result = []
      parallel_problems = []
      partitioned_problems.each do |partitioned_problem|
        if partitioned_problem.serial
          result << parallel_problems unless parallel_problems.empty?
          parallel_problems = []
          result << [partitioned_problem]
        else
          parallel_problems << partitioned_problem
        end
      end
      result << parallel_problems unless parallel_problems.empty?
      result
    end

    def get_instance_group_name(instance_id)
      instance = Models::Instance.where(id: instance_id).first
      instance.job
    end
  end
end
