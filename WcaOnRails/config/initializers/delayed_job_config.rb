# frozen_string_literal: true

require 'delayed/plugins/save_completed_jobs'

Delayed::Worker.destroy_failed_jobs = false
Delayed::Worker.max_run_time = 5.minutes
Delayed::Worker.delay_jobs = !Rails.env.test?
Delayed::Worker.plugins << Delayed::Plugins::SaveCompletedJobs
Delayed::Worker.logger = Logger.new(File.join(Rails.root, 'log', 'delayed_job.log'))
