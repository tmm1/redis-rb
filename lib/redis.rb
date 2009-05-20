require 'socket'
require 'set'
require File.join(File.dirname(__FILE__),'server')
require File.join(File.dirname(__FILE__),'pipeline')


class RedisError < StandardError
end
class RedisRenameError < StandardError
end
class Redis
  ERR = "-".freeze
  OK = 'OK'.freeze
  PONG = 'PONG'.freeze
  SINGLE = '+'.freeze
  BULK   = '$'.freeze
  MULTI  = '*'.freeze
  INT    = ':'.freeze
  
  attr_reader :server
  
  
  def initialize(opts={})
    @opts = {:host => 'localhost', :port => '6379', :db => 0}.merge(opts)
    $debug = @opts[:debug]
    @db = @opts[:db]
    @server = Server.new(@opts[:host], @opts[:port], (@opts[:timeout]||10))
  end
  
  def pipelined
    pipeline = Pipeline.new(self)
    yield pipeline
    pipeline.finish
  end
  
  def to_s
    "#{host}:#{port}"
  end
  
  def port
    @opts[:port]
  end
  
  def host
    @opts[:host]
  end
  
  def with_socket_management(server, &block)
    begin
      socket = server.socket
      block.call(socket)
    #Timeout or server down
    rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED, Timeout::Error => e
      server.close
      puts "Client (#{server.inspect}) disconnected from server: #{e.inspect}\n" if $debug
      retry
    #Server down
    rescue NoMethodError => e
      puts "Client (#{server.inspect}) tryin server that is down: #{e.inspect}\n Dying!" if $debug
      raise Errno::ECONNREFUSED
      #exit
    end
  end

  def monitor
    with_socket_management(@server) do |socket|
      trap("INT") { puts "\nGot ^C! Dying!"; exit }
      write "MONITOR\r\n"
      puts "Now Monitoring..."
      socket.read(12)
      loop do
        x = socket.gets
        puts x unless x.nil?
      end
    end
  end

  def quit
    write "QUIT\r\n"
  end
  
  def ping
    write "PING\r\n"
    get_response == PONG
  end

  def select_db(index)
    @db = index
    write "SELECT #{index}\r\n"
    get_response
  end
  
  def flush_db
    write "FLUSHDB\r\n"
    get_response == OK
  end    

  def flush_all
    puts "Warning!\nFlushing *ALL* databases!\n5 Seconds to Hit ^C!"
    trap('INT') {quit; return false}
    sleep 5
    write "FLUSHALL\r\n"
    get_response == OK
  end

  def last_save
    write "LASTSAVE\r\n"
    get_response.to_i
  end
  
  def bgsave
    write "BGSAVE\r\n"
    get_response == OK
  end  
    
  def info
   info = {}
   write("INFO\r\n")
   x = get_response
   x.each_line do |kv|
     k,v = kv.split(':', 2)
     k,v = k.chomp, v = v.chomp
     info[k.to_sym] = v
   end
   info
  end
  
  
  def bulk_reply
    begin
      x = read
      puts "bulk_reply read value is #{x.inspect}" if $debug
      return x
    rescue => e
      puts "error in bulk_reply #{e}" if $debug
      nil
    end
  end
  
  def write(data)
    with_socket_management(@server) do |socket|
      puts "writing: #{data}" if $debug
      socket.write(data)
    end
  end
  
  def fetch(len)
    with_socket_management(@server) do |socket|
      len = [0, len.to_i].max
      res = socket.read(len + 2)
      res = res.chomp if res
      res
    end
  end
  
  def read(length = read_proto)
    with_socket_management(@server) do |socket|
      res = socket.read(length)
      puts "read(#{length}) is #{res.inspect}" if $debug
      res
    end
  end

  def keys(glob)
    write "KEYS #{glob}\r\n"
    get_response.split(' ')
  end

  def rename!(oldkey, newkey)
    write "RENAME #{oldkey} #{newkey}\r\n"
    get_response
  end  
  
  def rename(oldkey, newkey)
    write "RENAMENX #{oldkey} #{newkey}\r\n"
    case get_response
    when -1
      raise RedisRenameError, "source key: #{oldkey} does not exist"
    when 0
      raise RedisRenameError, "target key: #{oldkey} already exists"
    when -3
      raise RedisRenameError, "source and destination keys are the same"
    when 1
      true
    end
  end  
  
  def key?(key)
    write "EXISTS #{key}\r\n"
    get_response == 1
  end  
  
  def delete(key)
    write "DEL #{key}\r\n"
    get_response == 1
  end  
  
  def [](key)
    get(key)
  end

  def get(key)
    write "GET #{key}\r\n"
    get_response
  end
  
  def mget(*keys)
    write "MGET #{keys.join(' ')}\r\n"
    get_response
  end

  def incr(key, increment=nil)
    if increment
      write "INCRBY #{key} #{increment}\r\n"
    else
      write "INCR #{key}\r\n"
    end    
    get_response
  end

  def decr(key, decrement=nil)
    if decrement
      write "DECRBY #{key} #{decrement}\r\n"
    else
      write "DECR #{key}\r\n"
    end    
    get_response
  end
  
  def randkey
    write "RANDOMKEY\r\n"
    get_response
  end

  def list_length(key)
    write "LLEN #{key}\r\n"
    case i = get_response
    when -2
      raise RedisError, "key: #{key} does not hold a list value"
    else
      i
    end
  end

  def type?(key)
    write "TYPE #{key}\r\n"
    get_response
  end
  
  def push_tail(key, val)
    write "RPUSH #{key} #{value_to_wire(val)}\r\n"
    get_response
  end      

  def push_head(key, val)
    write "LPUSH #{key} #{value_to_wire(val)}\r\n"
    get_response
  end
  
  def pop_head(key)
    write "LPOP #{key}\r\n"
    get_response
  end

  def pop_tail(key)
    write "RPOP #{key}\r\n"
    get_response
  end    

  def list_set(key, index, val)
    write "LSET #{key} #{index} #{value_to_wire(val)}\r\n"
    get_response == OK
  end

  def list_range(key, start, ending)
    write "LRANGE #{key} #{start} #{ending}\r\n"
    get_response
  end

  def list_trim(key, start, ending)
    write "LTRIM #{key} #{start} #{ending}\r\n"
    get_response
  end

  def list_index(key, index)
    write "LINDEX #{key} #{index}\r\n"
    get_response
  end

  def list_rm(key, count, val)
    write "LREM #{key} #{count} #{value_to_wire(val)}\r\n"
    case num = get_response
    when -1
      raise RedisError, "key: #{key} does not exist"
    when -2
      raise RedisError, "key: #{key} does not hold a list value"
    else
      num
    end
  end 

  def set_add(key, member)
    write "SADD #{key} #{value_to_wire(member)}\r\n"
    case get_response
    when 1
      true
    when 0
      false
    when -2
      raise RedisError, "key: #{key} contains a non set value"
    end
  end

  def set_delete(key, member)
    write "SREM #{key} #{value_to_wire(member)}\r\n"
    case get_response
    when 1
      true
    when 0
      false
    when -2
      raise RedisError, "key: #{key} contains a non set value"
    end
  end

  def set_count(key)
    write "SCARD #{key}\r\n"
    case i = get_response
    when -2
      raise RedisError, "key: #{key} contains a non set value"
    else
      i
    end
  end

  def set_member?(key, member)
    write "SISMEMBER #{key} #{value_to_wire(member)}\r\n"
    case get_response
    when 1
      true
    when 0
      false
    when -2
      raise RedisError, "key: #{key} contains a non set value"
    end
  end

  def set_members(key)
    write "SMEMBERS #{key}\r\n"
    Set.new(get_response)
  end

  def set_intersect(*keys)
    write "SINTER #{keys.join(' ')}\r\n"
    Set.new(get_response)
  end

  def set_inter_store(destkey, *keys)
    write "SINTERSTORE #{destkey} #{keys.join(' ')}\r\n"
    get_response
  end
  
  def set_union(*keys)
    write "SUNION #{keys.join(' ')}\r\n"
    Set.new(get_response)
  end

  def set_union_store(destkey, *keys)
    write "SUNIONSTORE #{destkey} #{keys.join(' ')}\r\n"
    get_response
  end
  
  def set_diff(*keys)
    write "SDIFF #{keys.join(' ')}\r\n"
    Set.new(get_response)
  end

  def set_diff_store(destkey, *keys)
    write "SDIFFSTORE #{destkey} #{keys.join(' ')}\r\n"
    get_response
  end

  def set_move(srckey, destkey, member)
    write "SMOVE #{srckey} #{destkey} #{value_to_wire(member)}\r\n"
    get_response == 1
  end

  def sort(key, opts={})
    cmd = "SORT #{key}"
    cmd << " BY #{opts[:by]}" if opts[:by]
    cmd << " GET #{opts[:get]}" if opts[:get]
    cmd << " INCR #{opts[:incr]}" if opts[:incr]
    cmd << " DEL #{opts[:del]}" if opts[:del]
    cmd << " DECR #{opts[:decr]}" if opts[:decr]
    cmd << " #{opts[:order]}" if opts[:order]
    cmd << " LIMIT #{opts[:limit].join(' ')}" if opts[:limit]
    cmd << "\r\n"
    write(cmd)
    get_response
  end
      
  def multi_bulk
    res = read_proto
    puts "mb res is #{res.inspect}" if $debug
    list = []
    Integer(res).times do
      vf = get_response
      puts "current vf is #{vf.inspect}" if $debug
      list << vf
      puts "current list is #{list.inspect}" if $debug
    end
    list
  end
   
  def get_reply
    begin
      r = read(1)
      raise RedisError if (r == "\r" || r == "\n")
    rescue RedisError
      retry
    end
    r
  end
   
  def []=(key, val)
    set(key,val)
  end
  

  def set(key, val, expiry=nil)
    write("SET #{key} #{value_to_wire(val)}\r\n")
    s = get_response == OK
    return expire(key, expiry) if s && expiry
    s
  end

  def dbsize
    write("DBSIZE\r\n")
    get_response
  end

  def expire(key, expiry=nil)
    write("EXPIRE #{key} #{expiry}\r\n")
    get_response == 1
  end

  def set_unless_exists(key, val)
    write "SETNX #{key} #{value_to_wire(val)}\r\n"
    get_response == 1
  end  
  
  def status_code_reply
    begin
      res = read_proto  
      if res.index('-') == 0          
        raise RedisError, res
      else          
        true
      end
    rescue RedisError
       raise RedisError
    end
  end
  
  def get_response
    begin
      rtype = get_reply
    rescue => e
      raise RedisError, e.inspect
    end
    puts "reply_type is #{rtype.inspect}" if $debug
    case rtype
    when SINGLE
      single_line
    when BULK
      bulk_reply
    when MULTI
      multi_bulk
    when INT
      integer_reply
    when ERR
      raise RedisError, single_line
    else
      raise RedisError, "Unknown response.. (reply_type: #{rtype.inspect})"
    end
  end
  
  def integer_reply
    Integer(read_proto)
  end
  
  def single_line
    buff = ""
    while buff[-2..-1] != "\r\n"
      buff << read(1)
    end
    puts "single_line value is #{buff[0..-3].inspect}" if $debug
    buff[0..-3]
  end
  
  def read_socket
    begin
      socket = @server.socket
      while res = socket.read(8096)
        break if res.size != 8096
      end
    #Timeout or server down
    rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED => e
      server.close
      puts "Client (#{server.inspect}) disconnected from server: #{e.inspect}\n" if $debug
      retry
    rescue Timeout::Error => e
    #BTM - Ignore this error so we don't go into an endless loop
      puts "Client (#{server.inspect}) Timeout\n" if $debug
    #Server down
    rescue NoMethodError => e
      puts "Client (#{server.inspect}) tryin server that is down: #{e.inspect}\n Dying!" if $debug
      raise Errno::ECONNREFUSED
      #exit
    end
  end
  
  def read_proto
    with_socket_management(@server) do |socket|
      if res = socket.gets
        x = res.chomp
        puts "read_proto is #{x.inspect}\n\n" if $debug
        x.to_i
      end
    end
  end

  private
  def value_to_wire(value)
    value_str = value.to_s
    if value_str.respond_to?(:bytesize)
      value_size = value_str.bytesize
    else
      value_size = value_str.size
    end
    "#{value_size}\r\n#{value_str}"
  end
  
end
