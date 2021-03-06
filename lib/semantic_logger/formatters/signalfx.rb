require 'json'
module SemanticLogger
  module Formatters
    class Signalfx < Base
      attr_accessor :token, :dimensions, :hash, :log, :logger, :gauge_name, :counter_name, :environment

      def initialize(token:,
                     dimensions: nil,
                     log_host: true,
                     log_application: true,
                     gauge_name: 'Application.average',
                     counter_name: 'Application.counter',
                     environment: true)

        @token        = token
        @dimensions   = dimensions.map(&:to_sym) if dimensions
        @gauge_name   = gauge_name
        @counter_name = counter_name

        if environment == true
          @environment = defined?(Rails) ? Rails.env : ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
        elsif environment
          @environment = environment
        end

        super(time_format: :ms, log_host: log_host, log_application: log_application)
      end

      # Create SignalFx friendly metric.
      #   Strip leading '/'
      #   Convert remaining '/' to '.'
      def metric
        if log.dimensions
          name = log.metric.to_s.sub(/\A\/+/, '')
          name.gsub!('/', '.')
          hash[:metric] = name
        else
          # Extract class and action from metric name
          name  = log.metric.to_s.sub(/\A\/+/, '')
          names = name.split('/')
          h     = (hash[:dimensions] ||= {})
          if names.size > 1
            h[:action] = names.pop
            h[:class]  = names.join('::')
          else
            h[:class]  = 'Unknown'
            h[:action] = names.first || log.metric
          end

          hash[:metric] = log.duration ? gauge_name : counter_name
        end
      end

      # Date & time
      def time
        # 1 second resolution, represented as ms.
        hash[:timestamp] = log.time.to_i * 1000
      end

      # Value of this metric
      def value
        hash[:value] = log.metric_amount || log.duration || 1
      end

      # Dimensions for this metric
      def format_dimensions
        h = (hash[:dimensions] ||= {})
        if log.dimensions
          log.dimensions.each_pair do |name, value|
            value   = value.to_s
            h[name] = value unless value.empty?
          end
        else
          log.named_tags.each_pair do |name, value|
            name  = name.to_sym
            value = value.to_s
            next if value.empty?
            h[name] = value if dimensions && dimensions.include?(name)
          end
        end
        h[:host]        = logger.host if log_host && logger.host
        h[:application] = logger.application if log_application && logger.application
        h[:environment] = environment if environment
      end

      # Returns [Hash] log message in Signalfx format.
      def call(log, logger)
        self.hash   = {}
        self.log    = log
        self.logger = logger

        metric; time; value; format_dimensions

        # gauge, counter, or cumulative_counter
        data = {}
        if log.duration
          data[:gauge] = [hash]
          # Also send a count metric whenever it is a gauge so that it can be counted.
          unless log.dimensions
            count_hash          = hash.dup
            count_hash[:value]  = log.metric_amount || 1
            count_hash[:metric] = counter_name
            data[:counter]      = [count_hash]
          end
        else
          data[:counter] = [hash]
        end

        data.to_json
      end

      # Returns [Hash] a batch of log messages.
      # Signalfx has a minimum resolution of 1 second.
      # Metrics of the same type, time (second), and dimensions can be aggregated together.
      def batch(logs, logger)
        self.logger = logger

        data = {}
        logs.each do |log|
          self.hash = {}
          self.log  = log

          metric; time; value; format_dimensions

          if log.duration
            gauges = (data[:gauge] ||= [])
            add_gauge(gauges, hash)

            # Also send a count metric whenever it is a gauge so that it can be counted.
            unless log.dimensions
              count_hash          = hash.dup
              count_hash[:value]  = log.metric_amount || 1
              count_hash[:metric] = counter_name
              counters            = (data[:counter] ||= [])
              add_counter(counters, count_hash)
            end
          else
            counters = (data[:counter] ||= [])
            add_counter(counters, hash)
          end
        end

        # Average counters with the same time(s), name, and dimensions.
        if gauges = data[:gauge]
          gauges.each { |gauge| average_value(gauge) }
        end

        data.to_json
      end

      private

      def add_gauge(gauges, metric)
        # Collect counters with the same time (second), name, and dimensions.
        if existing = find_match(gauges, metric)
          existing_value = existing[:value]
          if existing_value.is_a?(Array)
            existing_value << metric[:value]
          else
            existing[:value] = [existing_value, metric[:value]]
          end
        else
          gauges << metric
        end
      end

      # Sum counters with the same time (second), name, and dimensions.
      def add_counter(counters, metric)
        existing = find_match(counters, metric)
        existing ? existing[:value] += metric[:value] : counters << metric
      end

      # Find Metrics with the same timestamp, metric name, and dimensions.
      def find_match(list, metric)
        list.find do |item|
          (item[:timestamp] == metric[:timestamp]) &&
            (item[:metric] == metric[:metric]) &&
            (item[:dimensions] == metric[:dimensions])
        end
      end

      # Average the values contained in the metrics
      if [].respond_to?(:sum)
        def average_value(gauge)
          return unless gauge[:value].is_a?(Array)
          values        = gauge[:value]
          gauge[:value] = values.sum.to_f / values.size
        end
      else
        def average_value(gauge)
          return unless gauge[:value].is_a?(Array)
          values        = gauge[:value]
          gauge[:value] = values.inject { |sum, el| sum + el }.to_f / values.size
        end
      end

    end
  end
end
