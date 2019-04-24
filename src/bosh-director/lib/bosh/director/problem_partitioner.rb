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
    class << self
      def partition(deployment, problems)
        problem_partitions_by_ig = problem_partitions_by_instance_group(deployment, problems)
        partition_problems_by_serial(problem_partitions_by_ig)
      end

      private

      def problem_partitions_by_instance_group(deployment, problems)
        deployment_config = DeploymentConfig.new(YAML.safe_load(deployment.manifest), nil)
        deployment_config.instance_groups.map do |instance_group|
          problems_for_ig = problems.select { |problem| get_instance_group_name(problem.resource_id) == instance_group.name }
          next if problems_for_ig.empty?
          ProblemPartition.new(
            problems_for_ig,
            instance_group.name,
            instance_group.serial,
            instance_group.max_in_flight,
          )
        end.compact!
      end

      def partition_problems_by_serial(problem_partitions_by_ig)
        result = []
        parallel_problem_partitions = []
        problem_partitions_by_ig.each do |problem_partition|
          if problem_partition.serial
            result << parallel_problem_partitions unless parallel_problem_partitions.empty?
            result << [problem_partition]

            parallel_problem_partitions = []
          else
            parallel_problem_partitions << problem_partition
          end
        end
        result << parallel_problem_partitions unless parallel_problem_partitions.empty?
        result
      end

      def get_instance_group_name(instance_id)
        Models::Instance.where(id: instance_id).first.job
      end
    end
  end
end
