require 'rubygems'
require 'nokogiri'
require 'open-uri'
require 'cgi'
require 'readline'
require 'enumerator'
require 'parsedate'

$:.unshift(File.dirname(__FILE__)) unless
  $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))

module Termtter
  VERSION = '0.2.3'

  class CommandNotFound < StandardError; end

  class Client

    @@hooks = []
    @@commands = {}

    def self.add_hook(&hook)
      @@hooks << hook
    end

    def self.clear_hooks
      @@hooks.clear
    end

    def self.add_command(regex, &block)
      @@commands[regex] = block
    end

    def self.clear_commands
      @@commands.clear
    end

    attr_reader :since_id

    def initialize
      configatron.set_default(:update_interval, 300)
      configatron.set_default(:debug, false)
      @user_name = configatron.user_name
      @password = configatron.password
      @update_interval = configatron.update_interval
      @debug = configatron.debug
    end

    def update_status(status)
      req = Net::HTTP::Post.new('/statuses/update.xml')
      req.basic_auth(@user_name, @password)
      req.add_field("User-Agent", "Termtter http://github.com/jugyo/termtter")
      req.add_field("X-Twitter-Client", "Termtter")
      req.add_field("X-Twitter-Client-URL", "http://github.com/jugyo/termtter")
      req.add_field("X-Twitter-Client-Version", "0.1")
      Net::HTTP.start("twitter.com", 80) do |http|
        http.request(req, "status=#{CGI.escape(status)}")
      end
    end

    def list_friends_timeline
      statuses = get_timeline("http://twitter.com/statuses/friends_timeline.xml")
      call_hooks(statuses, :list_friends_timeline)
    end

    def update_friends_timeline
      uri = "http://twitter.com/statuses/friends_timeline.xml"
      if @since_id && !@since_id.empty?
        uri += "?since_id=#{@since_id}"
      end

      statuses = get_timeline(uri, true)
      call_hooks(statuses, :update_friends_timeline)
    end

    def get_user_timeline(screen_name)
      statuses = get_timeline("http://twitter.com/statuses/user_timeline/#{screen_name}.xml")
      call_hooks(statuses, :list_user_timeline)
    end

    def search(query)
      doc = Nokogiri::XML(open('http://search.twitter.com/search.atom?q=' + CGI.escape(query)))

      statuses = []
      ns = {'atom' => 'http://www.w3.org/2005/Atom'}
      doc.xpath('//atom:entry', ns).each do |node|
        status = Status.new
        published = node.xpath('atom:published', ns).text
        status.created_at = Time.utc(*ParseDate::parsedate(published)).localtime
        status.text = CGI.unescapeHTML(node.xpath('atom:content', ns).text.gsub(/<\/?[^>]*>/, ''))
        name = node.xpath('atom:author/atom:name', ns).text
        status.user_screen_name = name.scan(/^([^\s]+) /).flatten[0]
        status.user_name = name.scan(/\((.*)\)/).flatten[0]
        statuses << status
      end

      call_hooks(statuses, :search)
      return statuses
    end

    def show(id)
      statuses = get_timeline("http://twitter.com/statuses/show/#{id}.xml")
      call_hooks(statuses, :show)
    end

    def replies
      statuses = get_timeline("http://twitter.com/statuses/replies.xml")
      call_hooks(statuses, :show)
    end

    def call_hooks(statuses, event)
      @@hooks.each do |h|
        begin
          h.call(statuses.dup, event)
        rescue => e
          puts "Error: #{e}"
          puts e.backtrace.join("\n")
        end
      end
    end

    def get_timeline(uri, update_since_id = false)
      doc = Nokogiri::XML(open(uri, :http_basic_authentication => [@user_name, @password]))

      statuses = []
      doc.xpath('//status').each do |node|
        status = Status.new
        %w(
          id text created_at truncated in_reply_to_status_id in_reply_to_user_id 
          user/id user/name user/screen_name
        ).each do |key|
          method = "#{key.gsub('/', '_')}=".to_sym
          status.send(method, node.xpath(key).text)
        end
        status.created_at = Time.utc(*ParseDate::parsedate(status.created_at)).localtime
        statuses << status
      end

      if update_since_id && !statuses.empty?
        @since_id = statuses[0].id
      end

      return statuses
    end

    def call_commands(text)
      return if text.empty?
      
      command_found = false
      @@commands.each do |key, command|
        if key =~ text
          command_found = true
          begin
            command.call(self, $~)
          rescue => e
            puts "Error: #{e}"
            puts e.backtrace.join("\n")
          end
        end
      end

      raise CommandNotFound unless command_found
    end

    def pause
      @pause = true
    end

    def resume
      @pause = false
      @update.run
    end

    def exit
      @update.kill
      @input.kill
    end

    def run
      @pause = false

      @update = Thread.new do
        loop do
          if @pause
            Thread.stop
          end
          update_friends_timeline()
          sleep @update_interval
        end
      end

      @input = Thread.new do
        while buf = Readline.readline("", true)
          begin
            call_commands(buf)
          rescue CommandNotFound => e
            puts "Unknown command \"#{buf}\""
            puts 'Enter "help" for instructions'
          rescue => e
            puts "Error: #{e}"
            puts e.backtrace.join("\n")
          end
        end
      end

      stty_save = `stty -g`.chomp
      trap("INT") { system "stty", stty_save; self.exit }

      @input.join
    end

  end

  class Status
    %w(
      id text created_at truncated in_reply_to_status_id in_reply_to_user_id 
      user_id user_name user_screen_name
    ).each do |attr|
      attr_accessor attr.to_sym
    end
  end

end
