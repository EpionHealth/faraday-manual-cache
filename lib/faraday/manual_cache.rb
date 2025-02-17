require 'faraday-manual-cache/configuration'
require 'faraday'

module Faraday
  # Middleware for caching Faraday responses based on a specified expiry.
  #
  # As with faraday-http-cache, it's recommended that this middleware be added
  # fairly low in the middleware stack.
  #
  # Currently accepts four arguments:
  #
  #   :conditions    - Conditional caching based on a lambda (default: GET/HEAD
  #                    requests)
  #   :expires_in    - Cache expiry, in seconds (default: 30).
  #   :logger        - A logger object to send cache hit/miss/write messages.

  class ManualCache < Faraday::Middleware
    DEFAULT_CACHE_KEY = ->(env) { env.url }
    DEFAULT_CONDITIONS = ->(env) do
      (env.method == :get || env.method == :head) && !error_respose?(env)
    end

    def initialize(app, *args)
      super(app)
      options = args.first || {}
      @conditions    = options.fetch(:conditions, DEFAULT_CONDITIONS)
      @expires_in    = options.fetch(:expires_in, 30)
      @logger        = options.fetch(:logger, nil)
      @cache_key     = options.fetch(:cache_key, DEFAULT_CACHE_KEY)
    end

    def call(env)
      dup.call!(env)
    end

    protected

    def call!(env)
      response_env = cached_response(env)

      if response_env
        response_env.response_headers['x-faraday-manual-cache'] = 'HIT'
        to_response(response_env)
      else
        @app.call(env).on_complete do |response_env|
          response_env.response_headers['x-faraday-manual-cache'] = 'MISS'
          cache_response(response_env)
        end
      end
    end

    def cache_response(env)
      return unless cacheable?(env) && !env.request_headers['x-faraday-manual-cache']

      info "Cache WRITE: #{key(env)}"

      env = env.dup

      # Typhoeus parallel manager is not serializable and will cause the cache write
      # to fail. Since a cached read won't result in a queued request while in
      # parallel mode, it's not needed and can be safely removed to avoid the error.
      if env.parallel?
        env.parallel_manager = nil
      end

      store.write(
        key(env),
        env,
        expires_in: expires_in(env)
      )
    end

    def cacheable?(env)
      @conditions.call(env)
    end

    def cached_response(env)
      if cacheable?(env) && !env.request_headers['x-faraday-manual-cache']
        response_env = store.fetch(key(env))
      end

      if response_env
        info "Cache HIT: #{key(env)}"
      else
        info "Cache MISS: #{key(env)}"
      end

      response_env
    end

    def info(message)
      @logger.info(message) unless @logger.nil?
    end

    def key(env)
      @cache_key.call(env)
    end

    def expires_in(env)
      @expires_in.respond_to?(:call) ? @expires_in.call(env) : @expires_in
    end

    def store
      @store ||= FaradayManualCache.configuration.memory_store
    end

    def to_response(env)
      env = env.dup
      env.response_headers['x-faraday-manual-cache'] = 'HIT'
      response = Response.new
      response.finish(env) unless env.parallel?
      env.response = response
    end

    def self.error_respose?(env)
      env.response&.status.to_i >= 400
    end

    private_class_method :error_respose?
  end
end
