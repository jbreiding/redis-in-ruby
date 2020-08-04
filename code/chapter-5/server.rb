require 'socket'
require 'timeout'
require 'logger'
require 'delegate'
require 'strscan'

LOG_LEVEL = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO

require_relative './expire_helper'
require_relative './get_command'
require_relative './set_command'
require_relative './ttl_command'
require_relative './pttl_command'

class RedisServer

  COMMANDS = {
    'GET' => GetCommand,
    'SET' => SetCommand,
    'TTL' => TtlCommand,
    'PTTL' => PttlCommand,
  }

  MAX_EXPIRE_LOOKUPS_PER_CYCLE = 20
  DEFAULT_FREQUENCY = 10 # How many times server_cron runs per second

  NullArray = Class.new(SimpleDelegator)
  NullBulkString = Class.new(SimpleDelegator)
  RESPError = Class.new(SimpleDelegator)
  SimpleString = Class.new(SimpleDelegator)
  TimeEvent = Struct.new(:process_at, :block)

  def initialize
    @logger = Logger.new(STDOUT)
    @logger.level = LOG_LEVEL

    @clients = []
    @data_store = {}
    @expires = {}

    @server = TCPServer.new 2000
    @time_events = []
    @logger.debug "Server started at: #{ Time.now }"
    add_time_event(Time.now.to_f.truncate + 1) do
      server_cron
    end

    start_event_loop
  end

  private

  def add_time_event(process_at, &block)
    @time_events << TimeEvent.new(process_at, block)
  end

  def nearest_time_event
    now = (Time.now.to_f * 1000).truncate
    nearest = nil
    @time_events.each do |time_event|
      if nearest.nil?
        nearest = time_event
      elsif time_event.process_at < nearest.process_at
        nearest = time_event
      else
        next
      end
    end

    nearest
  end

  def select_timeout
    if @time_events.any?
      nearest = nearest_time_event
      now = (Time.now.to_f * 1000).truncate
      if nearest.process_at < now
        0
      else
        (nearest.process_at - now) / 1000.0
      end
    else
      0
    end
  end

  def start_event_loop
    loop do
      timeout = select_timeout
      @logger.debug "select with a timeout of #{ timeout }"
      result = IO.select(@clients + [@server], [], [], timeout)
      sockets = result ? result[0] : []
      process_poll_events(sockets)
      process_time_events
    end
  end

  def process_poll_events(sockets)
    sockets.each do |socket|
      begin
        if socket.is_a?(TCPServer)
          @clients << @server.accept
        elsif socket.is_a?(TCPSocket)
          client_command_with_args = socket.read_nonblock(1024, exception: false)
          if client_command_with_args.nil?
            @clients.delete(socket)
          elsif client_command_with_args == :wait_readable
            # There's nothing to read from the client, we don't have to do anything
            next
          elsif client_command_with_args.strip.empty?
            @logger.debug "Empty request received from #{ client }"
          else
            split_commands(client_command_with_args) do |command_parts|
              p "Parsed: #{ command_parts }"
              response = handle_client_command(command_parts)
              @logger.debug "Response: #{ response }"
              socket.puts to_bulk_string(response)
            end
          end
        else
          raise "Unknown socket type: #{ socket }"
        end
      rescue Errno::ECONNRESET
        @clients.delete(socket)
      end
    end
  end

  def split_commands(command_string_from_client)
    total_chars = command_string_from_client.length
    scanner = StringScanner.new(command_string_from_client)

    until scanner.eos?
      command_parts = parse_value_from_string(scanner)
      raise "Not an array #{ command_string_from_client }" unless command_parts.is_a?(Array)

      p "yielding #{ command_parts }"
      yield command_parts

      p "yielded: #{ scanner.inspect }"
    end
  end

  def parse_value_from_string(scanner)
    p "entering parse"
    p scanner
    p scanner.string[scanner.charpos..-1]
    sleep 1
    type_char = scanner.getch
    case type_char
    when '+'
      puts 'Simple String'
      scanner.scan_until(/\r\n/).strip
    when '$'
      puts 'Bulk String'
      expected_length = scanner.scan(/\d+/).to_i
      raise "Unexpected length for #{ scanner.string }" if expected_length <= 0

      crlf = scanner.scan(/\r\n/)
      raise "Did not find crlf following string length: #{ scanner.string }" if crlf.nil?

      # p scanner
      # p scanner.string
      # p scanner.string[scanner.pos..-1]
      bulk_string = scanner.scan_until(/\r\n/)&.strip
      if expected_length != bulk_string&.length
        raise "Length mismatch: #{ bulk_string } vs #{ expected_length }"
      end
      bulk_string.strip
    when '-'
      puts "It's an Error"
      RESPError.new(scanner.scan_until(/\r\n/).strip)
    when '*'
      puts 'Array'
      expected_length = scanner.scan(/\d+/).to_i
      raise "Unexpected length for #{ scanner.string }" if expected_length < 0

      crlf = scanner.scan(/\r\n/)
      raise "Did not find crlf following array length: #{ scanner.string }" if crlf.nil?
      array_result = []
      puts "recursing #{expected_length} times"
      sleep 1
      p Time.now
      expected_length.times do
        array_result << parse_value_from_string(scanner)
      end

      array_result
    when ':'
      puts 'Integer'
      scanner.scan_until(/\r\n/).to_i
    else
      raise "Unknown data type #{ type_char }"
    end
  end

  def process_time_events
    @time_events.delete_if do |time_event|
      next if time_event.process_at > Time.now.to_f * 1000

      return_value = time_event.block.call

      if return_value.nil?
        true
      else
        time_event.process_at = (Time.now.to_f * 1000).truncate + return_value
        @logger.debug "Rescheduling time event #{ Time.at(time_event.process_at / 1000.0).to_f }"
        false
      end
    end
  end

  def handle_client_command(command_parts)
    # @logger.info "Received command:\n'#{ client_command_with_args }',\n#{ client_command_with_args.inspect }"
    # command_parts = client_command_with_args.split
    # command_parts = client_command_with_args.match(/\*(\d+)\r\n((?:.|\r|\n)*)/)[2].scan(/\$\d+\r\n(\w+)/).flatten
    p command_parts
    command_str = command_parts[0]
    args = command_parts[1..-1]

    command_class = COMMANDS[command_str]

    if command_class
      command = command_class.new(@data_store, @expires, args)
      command.call
    else
      formatted_args = args.map { |arg| "`#{ arg }`," }.join(' ')
      "(error) ERR unknown command `#{ command_str }`, with args beginning with: #{ formatted_args }"
    end
  end

  def server_cron
    start_timestamp = Time.now
    keys_fetched = 0

    @expires.each do |key, _|
      if @expires[key] < Time.now.to_f * 1000
        @logger.debug "Evicting #{ key }"
        @expires.delete(key)
        @data_store.delete(key)
      end

      keys_fetched += 1
      if keys_fetched >= MAX_EXPIRE_LOOKUPS_PER_CYCLE
        break
      end
    end

    end_timestamp = Time.now
    @logger.debug do
      sprintf(
        "Processed %i keys in %.3f ms", keys_fetched, (end_timestamp - start_timestamp) * 1000)
    end

    1000 / DEFAULT_FREQUENCY
  end

  def describe(command)
    case command
    when 'get'
      [
        'get',
        2,
        [ SimpleString.new('readonly'), SimpleString.new('fast') ],
        1,
        1,
        1,
        [ SimpleString.new('@read'), SimpleString.new('@string'), SimpleString.new('@fast') ]
      ]
    end
  end

  def to_resp_array(array)
    resp = "*#{ array.length }\r\n"
    array.each do |item|
      resp += if item.is_a?(Array)
                to_resp_array(item)
              elsif item.is_a?(Integer)
                ":#{ item }\r\n"
              elsif item.is_a?(SimpleString)
                "+#{ item }\r\n"
              else
                "$#{ item.to_s.length }\r\n#{ item }\r\n"
              end
    end
    resp
  end

  def to_bulk_string(string)
    if string.nil?
      "$-1\r\n"
    else
      "$#{ string.length}\r\n#{ string }\r\n"
    end
  end
end
