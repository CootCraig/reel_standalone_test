require 'rubygems'
require 'bundler/setup'
require 'trollop'
require 'celluloid/autostart'
require 'reel'
require 'cgi'
require 'json'
require 'date'

module ReelTests
  VERSION = '0.0.2'
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
      if test_opts[:test] == :ajax_increasing
      elsif test_opts[:test] == :ajax_long_poll
        TestAjaxLongPoll.new(@host,@port)
      end
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
            break
          when '/channels'
            handle_channels(connection)
          else
            request.respond :not_found, "<h1>404 - Not Found</h1>"
          end
        end
      end
      APP_LOGGER.debug "returning from on_connection"
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
  class TestAjaxLongPoll
    include Celluloid
    include Celluloid::Notifications
    def initialize(aHost,aPort)
      ReelTests::APP_LOGGER.info "TestAjaxLongPoll starting"
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
Notes for a gist for tarcieri or others
At this point options :ajax_increasing and :ajax_long_poll are not useful.  The ideas is to make
self running tests.
My test is 
$ jruby -S reel_test.rb

Then from a browser:
http://localhost:8091/events?channel=1

In the log I see:
D, [2013-09-11T14:21:04.524000 #2874] DEBUG -- : WebServer request method GET path /events url /events?channel=1 query_string channel=1 parsed {"channel"=>["1"]}
E, [2013-09-11T14:21:04.529000 #2874] ERROR -- : ReelTests::WebServer crashed!
Reel::Connection::StateError: already processing a request
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/bundler/gems/reel-470e33de44f8/lib/reel/connection.rb:55:in `request'
	reel_tests.rb:46:in `on_connection'
	org/jruby/RubyMethod.java:134:in `call'
	org/jruby/RubyProc.java:255:in `call'
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/bundler/gems/reel-470e33de44f8/lib/reel/server.rb:32:in `handle_connection'
	org/jruby/RubyBasicObject.java:1730:in `__send__'
	org/jruby/RubyKernel.java:1932:in `public_send'
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/gems/celluloid-0.15.1/lib/celluloid/calls.rb:25:in `dispatch'
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/gems/celluloid-0.15.1/lib/celluloid/calls.rb:122:in `dispatch'
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/gems/celluloid-0.15.1/lib/celluloid/actor.rb:322:in `handle_message'
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/gems/celluloid-0.15.1/lib/celluloid/actor.rb:416:in `task'
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/gems/celluloid-0.15.1/lib/celluloid/tasks.rb:55:in `initialize'
	/opt/ruby/jruby-1.7.4/lib/ruby/gems/shared/gems/celluloid-0.15.1/lib/celluloid/tasks/task_fiber.rb:13:in `create'
W, [2013-09-11T14:21:04.531000 #2874]  WARN -- : Terminating task: type=:call, meta={:method_name=>:run}, status=:iowait

=end

=begin
Craig's notes:

This looks promising, when we detach the connection the request(?) should
be set as ready to respond.

--- dev/reel/lib/reel/request_parser.rb
# Mark current request as complete, set this as ready to respond.
def on_message_complete
  @currently_reading.finish_reading! if @currently_reading.is_a?(Request)
  if @currently_responding.nil?
    @currently_responding = @currently_reading
  else
    @pending_responses << @currently_reading
  end
  @currently_reading = @pending_reads.shift
end

So what calls #on_message_complete ?

--- dev/reel/lib/reel/request_parser.rb
module Reel
  class Request
    class Parser
      def initialize(sock, conn)
        @parser = Http::Parser.new(self)

gem "http_parser.rb", "~> 0.5.3"
Ruby bindings to http://github.com/ry/http-parser and http://github.com/a2800276/http-parser.java

=end

