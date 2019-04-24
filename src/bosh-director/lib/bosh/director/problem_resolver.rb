module Bosh::Director
  class ProblemResolver

    attr_reader :logger

    def initialize(deployment)
      @deployment = deployment
      @resolved_count = 0
      @resolution_error_logs = StringIO.new

      #temp
      @event_log_stage = nil
      @logger = Config.logger
    end

    def begin_stage(stage_name, n_steps)
      @event_log_stage = Config.event_log.begin_stage(stage_name, n_steps)
      logger.info(stage_name)
    end

    def track_and_log(task, log = true)
      @event_log_stage.advance_and_track(task) do |ticker|
        logger.info(task) if log
        yield ticker if block_given?
      end
    end

    def apply_resolutions(resolutions)
      @resolutions = resolutions
      problems = Models::DeploymentProblem.where(id: resolutions.keys.map(&:to_i)).all

      begin_stage('Applying problem resolutions', problems.count)
      if Config.parallel_problem_resolution
        all_problem_partitions = ProblemPartitioner.partition(@deployment, problems)
        all_problem_partitions.each do |problem_partitions|
          process_problem_partitions(problem_partitions)
        end
      else
        problems.each do |problem|
          process_problem(problem)
        end
      end

      error_message = @resolution_error_logs.string.empty? ? nil : @resolution_error_logs.string.chomp
      [@resolved_count, error_message]
    end

    private

    def process_problem_partitions(problem_partitions)
      #if problem_partitions.length > 1
        ThreadPool.new(max_threads: Config.max_threads).wrap do |pool|
          problem_partitions.each do |problem_partition|
            pool.process do
              process_problem_partition(problem_partition)
            end
          end
        end
      #else
      #  process_problem_partition(problem_partitions.first) unless problem_partitions.empty?
      #end
    end

    def process_problem_partition(problem_partition)
      ThreadPool.new(max_threads: problem_partition.max_in_flight).wrap do |problem_pool|
        problem_partition.problems.each do |problem|
          problem_pool.process do
            process_problem(problem)
          end
        end
      end
    end

    def process_problem(problem)
      if problem.state != 'open'
        reason = "state is '#{problem.state}'"
        track_and_log("Ignoring problem #{problem.id} (#{reason})")
      elsif problem.deployment_id != @deployment.id
        reason = 'not a part of this deployment'
        track_and_log("Ignoring problem #{problem.id} (#{reason})")
      else
        apply_resolution(problem)
      end
    end

    def apply_resolution(problem)
      handler = ProblemHandlers::Base.create_from_model(problem)
      handler.job = self

      resolution = @resolutions[problem.id.to_s] || handler.auto_resolution
      problem_summary = "#{problem.type} #{problem.resource_id}"
      resolution_summary = handler.resolution_plan(resolution)
      resolution_summary ||= 'no resolution'

      begin
        track_and_log("#{problem.description} (#{problem_summary}): #{resolution_summary}") do
          handler.apply_resolution(resolution)
        end
      rescue Bosh::Director::ProblemHandlerError => e
        log_resolution_error(problem, e)
      end

      problem.state = 'resolved'
      problem.save
      @resolved_count += 1

    rescue => e
      log_resolution_error(problem, e)
    end

    def log_resolution_error(problem, error)
      error_message = "Error resolving problem '#{problem.id}': #{error}"
      logger.error(error_message)
      logger.error(error.backtrace.join("\n"))
      @resolution_error_logs.puts(error_message)
    end
  end
end
