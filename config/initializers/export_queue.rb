Rails.application.config.active_job.queue_adapter = :solid_queue unless Rails.env.test?
