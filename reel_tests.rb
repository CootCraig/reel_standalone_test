require 'rubygems'
require 'bundler/setup'
require 'trollop'
require 'celluloid/autostart'
require 'reel'
require 'cgi'
require 'json'
require 'date'

module ReelTests
  VERSION = '0.0.1'
  APP_LOGGER = Logger.new('log.txt');

  Celluloid.logger = APP_LOGGER

  class WebServer < Reel::Server
    EXTRA_HEADERS = { :'Access-Control-Allow-Origin' => '*' }
    def initialize(test_opts)
      @host = test_opts[:host]
      @port = test_opts[:port]
      @test = test_opts[:test]

      @increasing_data = []
      @channels = [1,2,3]
      start_channel_sources
      DistributeEvents.supervise_as(:distribute_events, @channels)
      super(@host, @port, &method(:on_connection))
    end
    def on_connection(connection)
      while request = connection.request
        if !request.websocket?
          query_string = request.query_string || ''
          APP_LOGGER.debug "WebServer request method #{request.method} path #{request.path} url #{request.url} query_string #{query_string} parsed #{CGI::parse(query_string)}"
          case request.path
          when '/increasing'
            handle_increasing(connection)
          when '/events'
            handle_events(connection,request)
          when '/channels'
            handle_channels(connection)
          else
            request.respond :not_found, "<h1>404 - Not Found</h1>"
          end
        end
      end
    end
    def start_channel_sources
      @channels.each do |channel|
        ChannelSource.supervise_as :"channel_#{channel.to_s}", channel
      end
    end
    def handle_channels(connection)
      connection.respond :ok, EXTRA_HEADERS, @channels.to_json
    end
    def handle_events(connection,request)
      valid_channel = false
      query_string = request.query_string || ''
      query_hash = CGI::parse(query_string)
      if query_hash['channel'] && (query_hash['channel'].length > 0)
        channel = query_hash['channel'][0]
        if @channels.include?(channel.to_i(10))
          valid_channel = true
          request.body.to_s
          connection.detach
          Celluloid::Actor[:distribute_events].async.request_event(connection,channel)
        end
      end
      unless valid_channel
        connection.respond :not_found, "<h1>404 - Not Found #{query_hash}</h1>"
      end
    end
    def handle_increasing(connection)
      connection.respond :ok, EXTRA_HEADERS, increasing_payload
    end
    def increasing_payload
      new_item = @increasing_data.length + 1
      @increasing_data << new_item
      @increasing_data.to_json
    end
  end
  class ChannelSource
    include Celluloid
    include Celluloid::Notifications

    def self.channel_topic(channel)
      channel.to_s
    end
    def initialize(channel)
      @channel = ChannelSource::channel_topic(channel)
      @counter = 0
      APP_LOGGER.debug "ChannelSource #{@channel} starting"
      schedule
    end
    def publish_event
      @counter += 1
      data = {channel: @channel, counter: @counter, time: DateTime.now.to_s }
      payload = data.to_json
      APP_LOGGER.debug payload
      publish @channel,payload
      schedule
    end
    def schedule
      after (rand_delay) { async.publish_event }
    end
    def rand_delay
      return 4 + rand(8)
    end
  end
  class DistributeEvents
    include Celluloid
    include Celluloid::Notifications

    def initialize(aChannels)
      @channels = {}
      aChannels.each do |channel|
        topic = ChannelSource::channel_topic(channel)
        @channels[topic] = []
        subscribe(topic,:distribute)
      end
    end
    def distribute(topic,payload)
      if @channels[topic]
        while @channels[topic].length > 0
          connection = @channels[topic].pop
          begin
            connection.respond :ok, WebServer::EXTRA_HEADERS, payload
            connection.close
          rescue Reel::SocketError
            ReelTests::APP_LOGGER.debug "Ajax client disconnected"
          rescue => ex
            ReelTests::APP_LOGGER.error "DistributeEvents.distribute #{ex.message}"
          end
        end
      end
    end
    def request_event(connection,channel)
      topic = ChannelSource::channel_topic(channel)
      @channels[topic] << connection
    end
  end

end

opts = Trollop::options do
  version "reel_tests #{ReelTests::VERSION} (c) 2013 Craig Anderson"
  opt :host, "Host for Reel HTTP", :default => '0.0.0.0'
  opt :port, "Port for Reel HTTP", :default => 8091
  opt :ajax_increasing, "Test a series of Ajax calls the the payload size always increasing"
  opt :ajax_long_poll, "Test a series of Ajax long poll calls with a delayed response"
end

test_opts = {host: opts[:host], port: opts[:port]}
if opts[:ajax_increasing]
  test_opts[:test] = :ajax_increasing
elsif opts[:ajax_long_poll]
  test_opts[:test] = :ajax_long_poll
else
  test_opts[:test] = :server
end

ReelTests::APP_LOGGER.info "\n===\n=== Reel test run at #{test_opts[:host]}:#{test_opts[:port]} test #{test_opts[:test].to_s}\n==="

Celluloid::Actor[:web_server] = ReelTests::WebServer.new(test_opts)
sleep

=begin
=end

