require 'rubygems'
require 'json'
require 'open-uri'
require 'cgi'
require 'readline'
require 'enumerator'
require 'parsedate'

$:.unshift(File.dirname(__FILE__)) unless
  $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))

module Termtter
  VERSION = '0.4.0'

  class Twitter

    def initialize(user_name, password)
      @user_name = user_name
      @password = password
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

    def get_friends_timeline(since_id = nil)
      uri = "http://twitter.com/statuses/friends_timeline.json"
      uri += "?since_id=#{since_id}" if since_id
      return get_timeline(uri)
    end

    def get_user_timeline(screen_name)
      return get_timeline("http://twitter.com/statuses/user_timeline/#{screen_name}.json")
    end

    def search(query)
      results = JSON.parse(open('http://search.twitter.com/search.json?q=' + CGI.escape(query)).read)['results']
      return results.inject([]) do |statuses, s|
        status = Status.new
        status.text = s['text']
        status.created_at = Time.utc(*ParseDate::parsedate(s["created_at"])).localtime
        status.user_screen_name = s['from_user']
        statuses << status
      end
    end

    def show(id)
      return get_timeline("http://twitter.com/statuses/show/#{id}.json")
    end

    def replies
      return get_timeline("http://twitter.com/statuses/replies.json")
    end

    def get_timeline(uri)
      data = JSON.parse(open(uri, :http_basic_authentication => [@user_name, @password]).read)
      data =  if data.instance_of? Array
                data
              else
                [data]
              end
      return data.inject([]) do |statuses, s|
        u = s["user"]
        status = Status.new
        status.created_at = Time.utc(*ParseDate::parsedate(s["created_at"])).localtime
        %w(id text truncated in_reply_to_status_id in_reply_to_user_id).each do |key|
          status.send("#{key}=".to_sym, s[key])
        end
        %w(id name screen_name url profile_image_url).each do |key|
          status.send("user_#{key}=".to_sym, u[key])
        end
        statuses << status
      end
    end
  end

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

    def self.public_storage
      @@public_storage ||= {}
      return @@public_storage
    end

    def self.call_hooks(statuses, event, tw)
      @@hooks.each do |h|
        begin
          h.call(statuses.dup, event, tw)
        rescue => e
          puts "Error: #{e}"
          puts e.backtrace.join("\n")
        end
      end
    end

    def self.call_commands(text, tw)
      return if text.empty?

      command_found = false
      @@commands.each do |key, command|
        if key =~ text
          command_found = true
          begin
            command.call($~, tw)
          rescue => e
            puts "Error: #{e}"
            puts e.backtrace.join("\n")
          end
        end
      end

      raise CommandNotFound unless command_found
    end

    def self.pause
      @@pause = true
    end

    def self.resume
      @@pause = false
      @@update.run
    end

    def self.exit
      @@update.kill
      @@input.kill
    end

    def self.run
      @@pause = false
      tw = Termtter::Twitter.new(configatron.user_name, configatron.password)

      @@update = Thread.new do
        since_id = nil
        loop do
          begin
            Thread.stop if @@pause

            statuses = tw.get_friends_timeline(since_id)
            unless statuses.empty?
              since_id = statuses[0].id
            end
            call_hooks(statuses, :update_friends_timeline, tw)

          rescue => e
            puts "Error: #{e}"
            puts e.backtrace.join("\n")
          ensure
            sleep configatron.update_interval
          end
        end
      end

      @@input = Thread.new do
        while buf = Readline.readline("", true)
          begin
            call_commands(buf, tw)
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
      trap("INT") { system "stty", stty_save; exit }

      @@input.join
    end

  end

  class CommandNotFound < StandardError; end

  class Status
    %w(
      id text created_at truncated in_reply_to_status_id in_reply_to_user_id 
      user_id user_name user_screen_name user_url user_profile_image_url
    ).each do |attr|
      attr_accessor attr.to_sym
    end
  end

end
