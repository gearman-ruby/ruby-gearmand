require 'set'
module Rgearmand
  class WorkerQueue
    attr_reader :workers, :capabilities, :hostname
    attr_writer :persistent_queue
    def initialize(hostname = `hostname`.chomp)
      # Jobs to run
      @queues = {}
      
      # Jobs being run currently, indexed by job_handle
      @jobs = {}
      
      # Clients requiring work, indexed by job_handle
      @clients = {}
      
      # A unique id holder
      @state_id = 0
      
      # Worker connections indexed by function name
      @workers = {}
      
      # Inverse of @workers, which lists capabilities for a given worker.
      @worker_by_connection = {}
      
      @hostname = hostname
      logger.debug("Starting Worker Queue")    
    end
        
    def get_job_handle
      "H:#{@hostname}:#{$$}:#{@state_id += 1}"
    end
    
    # Add a job to the running queue.
    def add(job_handle, client, job)
      @clients[job_handle] = client
      @jobs[job_handle] = job
    end
    
    def each_worker(func_name, &block)
      return unless @workers.has_key?(func_name)
      @workers[func_name].each(&block)
    end
    
    def status(job_handle)
      return [0,0,0,0] unless @jobs.has_key?(job_handle)
      return [0,0,0,0] if @jobs[job_handle][:numerator].nil?
      
      # We have status, so send it off
      numerator = @jobs[job_handle][:numerator]
      denominator = @jobs[job_handle][:denominator]
      [1, 0, numerator, denominator]
    end
    
    def set_status(job_handle, numerator, denominator)
      @jobs[job_handle][:numerator] = numerator
      @jobs[job_handle][:denominator] = denominator
    end
    
    def client(job_handle)
      if !@jobs.has_key?(job_handle)
        return logger.debug "No job handle #{job_handle}..."
      end
      
      if !@clients[job_handle]
        return logger.debug "No client for job handle #{job_handle}..."
      end
      
      yield @clients[job_handle]
    end
    
    def can_do(func_name, connection)
      @workers[func_name] ||= []
      @workers[func_name] << connection
    end
    
    def cant_do(func_name, connection)
      return if !@workers.has_key?(func_name)
      
      @workers[func_name].delete(connection)
    end
    
    # XXX: Clean this?
    def grab_job_local(capabilities)
      capabilities.each do |cap|
        logger.debug "Checking for #{cap}"
        queues = @queues[cap] || {}
          ["high", "normal", "low"].each do |priority|
          next unless queues.has_key?(priority)
          
          job_queue = queues[priority]
          if job_queue.size == 0
            logger.debug "No jobs ready to run in #{priority} priority."
            next
          end

          job = job_queue.next
          next if !capabilities.include?(job.func_name)
          if job.timestamp == 0 || job.timestamp <= Time.now().to_i
            job_queue.pop
            logger.debug job.inspect
            logger.debug "Found job: #{job.inspect}"

            if !@jobs.has_key?(job.job_handle)
              logger.debug "Adding to run queue..."
              @jobs[job.job_handle] = job
            end
            job.started_at = Time.now()
            return job
          end
        end
      end
      
      nil
    end
    
    def grab_job(capabilities)
      current_time = Time.now().to_i
      capabilities.each do |func_name|
        logger.debug "Checking for #{func_name}"
        ["high", "normal", "low"].each do |priority|
          job = @persistent_queue.retrieve_next(func_name, priority)
          if job && !@jobs.has_key?(job.job_handle)
            logger.debug "Adding to run queue..."
            @jobs[job.job_handle] = job
            return job
          end
        end
      end

      logger.debug "No job for this worker"
      nil
    end
    
    def enqueue(opts = {})
      func_name = opts[:func_name] || opts["func_name"]
      priority = opts[:priority] || opts["priority"] || "normal"
      uniq = opts[:uniq] || opts["uniq"] || UUIDTools::UUID.random_create
      data = opts[:data] || opts["data"] 
      timestamp = opts[:timestamp] || opts["timestamp"] || 0
      timestamp = Time.at(timestamp.to_i)
      job_handle = get_job_handle
      job = @persistent_queue.store!(func_name, data, uniq, timestamp, priority, job_handle)
      return job.job_handle
    end

    def dequeue(job_handle)
      job = @jobs[job_handle]
      if job != nil
        @persistent_queue.delete!(job)
      end
      @jobs.delete(job_handle)
      return job
    end
  end
end
