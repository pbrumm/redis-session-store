# vim:fileencoding=utf-8
require 'redis'
require 'thread'

# Redis session storage for Rails, and for Rails only. Derived from
# the MemCacheStore code, simply dropping in Redis instead.
class RedisSessionStore < ActionDispatch::Session::AbstractStore
  VERSION = '0.8.0'
  # Rails 3.1 and beyond defines the constant elsewhere
  unless defined?(ENV_SESSION_OPTIONS_KEY)
    if Rack.release.split('.').first.to_i > 1
      ENV_SESSION_OPTIONS_KEY = Rack::RACK_SESSION_OPTIONS
    else
      ENV_SESSION_OPTIONS_KEY = Rack::Session::Abstract::ENV_SESSION_OPTIONS_KEY
    end
  end


  # ==== Options
  # * +:key+ - Same as with the other cookie stores, key name
  # * +:redis+ - A hash with redis-specific options
  #   * +:host+ - Redis host name, default is localhost
  #   * +:port+ - Redis port, default is 6379
  #   * +:db+ - Database number, defaults to 0.
  #   * +:key_prefix+ - Prefix for keys used in Redis, e.g. +myapp:+
  #   * +:expire_after+ - A number in seconds for session timeout
  #   * +:client+ - Connect to Redis with given object rather than create one
  # * +:on_redis_down:+ - Called with err, env, and SID on Errno::ECONNREFUSED
  # * +:on_session_load_error:+ - Called with err and SID on Marshal.load fail
  # * +:serializer:+ - Serializer to use on session data, default is :marshal.
  #
  # ==== Examples
  #
  #     My::Application.config.session_store :redis_session_store, {
  #       key: 'your_session_key',
  #       redis: {
  #         db: 2,
  #         expire_after: 120.minutes,
  #         key_prefix: 'myapp:session:',
  #         host: 'host', # Redis host name, default is localhost
  #         port: 12345   # Redis port, default is 6379
  #       },
  #       on_redis_down: ->(*a) { logger.error("Redis down! #{a.inspect}") }
  #       serializer: :hybrid # migrate from Marshal to JSON
  #     }
  #
  def initialize(app, options = {})
    super
    @connection_mutex = Mutex.new
    @last_reconnect = nil
    redis_options = options[:redis] || {}

    @default_options.merge!(namespace: 'rack:session')
    @default_options.merge!(redis_options)
    @default_options.merge!(redis: redis_options)
    initialize_redis_connection
    @on_redis_down = options[:on_redis_down]
    @serializer = determine_serializer(options[:serializer])
    @on_session_load_error = options[:on_session_load_error]
    verify_handlers!
  end

  attr_accessor :on_redis_down, :on_session_load_error

  private

  attr_reader :redis, :key, :default_options, :serializer

  def initialize_redis_connection
    @connection_mutex.synchronize {
      if @last_reconnect.nil? || @last_reconnect < Time.now - 1
        @redis = @default_options[:client] || Redis.new(@default_options[:redis])
        @last_reconnect = Time.now
      end
    }
  end
  # overrides method defined in rack to actually verify session existence
  # Prevents needless new sessions from being created in scenario where
  # user HAS session id, but it already expired, or is invalid for some
  # other reason, and session was accessed only for reading.
  def session_exists?(env)
    value = current_session_id(env)

    if value && !value.empty?
      response = nil
      retry_and_reconnect_if_not_master do
        response = redis.exists(prefixed(value))
      end
      response
    else
      false
    end

  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, env, value) if on_redis_down

    true
  end

  def verify_handlers!
    %w(on_redis_down on_session_load_error).each do |h|
      next unless (handler = public_send(h)) && !handler.respond_to?(:call)

      fail ArgumentError, "#{h} handler is not callable"
    end
  end

  def prefixed(sid)
    "#{default_options[:key_prefix]}#{sid}"
  end

  def get_session(env, sid)
    if sid
      session = nil
      retry_and_reconnect_if_not_master do
        session = load_session_from_redis(sid)
      end
      if session.nil?
        sid = generate_sid
        session = {}
      end
    end

    [sid, session]
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, env, sid) if on_redis_down
    [generate_sid, {}]
  end

  def load_session_from_redis(sid)
    data = nil
    retry_and_reconnect_if_not_master do
      data = redis.get(prefixed(sid))
    end
    begin
      data ? decode(data) : nil
    rescue => e
      destroy_session_from_sid(sid, drop: true)
      on_session_load_error.call(e, sid) if on_session_load_error
      nil
    end
  end

  def decode(data)
    serializer.load(data)
  end
  def retry_and_reconnect_if_not_master
    begin
      yield
    rescue Redis::CommandError => e
      initialize_redis_connection
      yield
    rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
      initialize_redis_connection
      yield
    end
  end
  def set_session(env, sid, session_data, options = nil) # rubocop: disable MethodLength, LineLength
    expiry = (options || env.fetch(ENV_SESSION_OPTIONS_KEY))[:expire_after]
    retry_and_reconnect_if_not_master do
      if expiry
        redis.setex(prefixed(sid), expiry, encode(session_data))
      else
        redis.set(prefixed(sid), encode(session_data))
      end

    end
    return sid
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, env, sid) if on_redis_down
    return false
  end

  def encode(session_data)
    serializer.dump(session_data)
  end

  def destroy_session(env, sid, options)
    destroy_session_from_sid(sid, (options || {}).to_hash.merge(env: env))
  end

  def destroy(env)
    if env['rack.request.cookie_hash'] &&
       (sid = env['rack.request.cookie_hash'][key])
      destroy_session_from_sid(sid, drop: true, env: env)
    end
    false
  end

  def destroy_session_from_sid(sid, options = {})
    retry_and_reconnect_if_not_master do
      redis.del(prefixed(sid))
    end
    (options || {})[:drop] ? nil : generate_sid
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, options[:env] || {}, sid) if on_redis_down
  end

  def determine_serializer(serializer)
    serializer ||= :marshal
    case serializer
    when :marshal then Marshal
    when :json    then JsonSerializer
    when :hybrid  then HybridSerializer
    else serializer
    end
  end

  # Uses built-in JSON library to encode/decode session
  class JsonSerializer
    def self.load(value)
      JSON.parse(value, quirks_mode: true)
    end

    def self.dump(value)
      JSON.generate(value, quirks_mode: true)
    end
  end

  # Transparently migrates existing session values from Marshal to JSON
  class HybridSerializer < JsonSerializer
    MARSHAL_SIGNATURE = "\x04\x08".freeze

    def self.load(value)
      if needs_migration?(value)
        Marshal.load(value)
      else
        super
      end
    end

    def self.needs_migration?(value)
      value.start_with?(MARSHAL_SIGNATURE)
    end
  end
end
