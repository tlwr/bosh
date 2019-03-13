require_relative 'jobs/update_deployment'

module Bosh::Director
  class ProblemResolver
    include DeploymentPlan
    include Jobs

    attr_reader :logger

    def initialize(deployment)
      @deployment = deployment
      @resolved_count = 0
      @resolution_error_logs = StringIO.new
      update_deployment = UpdateDeployment.new(
        @deployment.manifest,
        @deployment.cloud_configs.map(&:id),
        @deployment.runtime_configs.map(&:id),
      )
      @instance_groups = update_deployment.deployment_plan.instance_groups

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
      problems = Models::DeploymentProblem.where(id: resolutions.keys)

      begin_stage('Applying problem resolutions', problems.count)

      if Config.parallel_problem_resolution
        # TODO: here we just assume :type recreate VM,
        # make sure that other problem types like re-attach disk still work
        problems_ordered_by_job(problems.all) do |probs, max_in_flight|
          number_of_threads = [probs.size, max_in_flight].min
          ThreadPool.new(max_threads: number_of_threads).wrap do |pool|
            probs.each do |problem|
              pool.process do
                process_problem(problem)
              end
            end
          end
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

    def problems_ordered_by_job(problems, &block)
      BatchMultiInstanceGroupUpdater.partition_jobs_by_serial(@instance_groups).each do |jp|
        if jp.first.update.serial?
          # all instance groups in this partition are serial
          jp.each do |ig|
            process_ig(ig, problems, block)
          end
        else
          # all instance groups in this partition are non-serial
          # therefore, parallelize recreation of all instances in this partition
          # therefore, create an outer ThreadPool as ParallelMultiInstanceGroupUpdater does it in the regular deploy flow

          # TODO: might not want to create a new thread for instance_groups without problems
          ThreadPool.new(max_threads: jp.size).wrap do |pool|
            jp.each do |ig|
              pool.process do
                process_ig(ig, problems, block)
              end
            end
          end
        end
      end
    end

    def process_ig(ig, problems, block)
      instance_group = @instance_groups.find do |plan_ig|
        plan_ig.name == ig.name
      end
      probs = select_problems_by_instance_group(problems, ig)
      max_in_flight = instance_group.update.max_in_flight(probs.size)
      # within an instance_group parallelize recreation of all instances
      block.call(probs, max_in_flight)
    end

    def select_problems_by_instance_group(problems, instance_group)
      problems.select do |p|
        # TODO do not select the instance of every problem
        # instead: push the instance_group.name condition to the database (by a second where clause?)
        instance = Models::Instance.where(:id=>p.resource_id).first # resource_id corresponds to the primary key of the instances table
        instance.job == instance_group.name
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
