require 'uart'
require 'io/wait'
require 'webrick'
require 'json'

class Particular
  VERSION = '1.0.0'

  include UART

  class Sample < Struct.new(:time,
                            :pm1_0_standard, :pm2_5_standard, :pm10_standard,
                            :pm1_0_env,      :pm2_5_env,
                            :concentration_unit,
                            :particle_03um,   :particle_05um,   :particle_10um,
                            :particle_25um,   :particle_50um,   :particle_100um)
    def for_json
      to_h.tap do |hash|
        hash[:time] = hash[:time].strftime("%FT%T.%L%:z")
      end
    end
  end

  def initialize path
    @file = open path, 9600, '8N1'
  end

  def read
    @file.wait_readable
    start1, start2 = @file.read(2).bytes

    # According to the data sheet, packets always start with 0x42 and 0x4d
    unless start1 == 0x42 && start2 == 0x4d
      # skip a sample
      @file.read
      return read
    end

    length = @file.read(2).unpack('n').first
    data = @file.read(length)
    crc  = 0x42 + 0x4d + 28 + data.bytes.first(26).inject(:+)
    data = data.unpack('n14')
    if crc != data.last
      return read
    end
    Sample.new(Time.now.utc, *data.first(12))
  end

  module WebServer
    class TTYServlet < WEBrick::HTTPServlet::AbstractServlet
      def initialize server, client, mutex
        super server
        @client = client
        @mutex  = mutex
      end
    end

    class SampleServlet < TTYServlet
      def do_GET request, response
        response.status = 200
        response['Content-Type'] = 'text/event-stream'
        @mutex.synchronize do
          rd, wr = IO.pipe
          response.body = rd
          response.chunked = true
          Thread.new {
            while data = @client.read
              wr.write "data:#{JSON.dump(data.for_json)}\n\n"
            end
          }
        end
      end
    end

    def self.start tty
      root = File.expand_path(File.join File.dirname(__FILE__), 'particular', 'public')
      mutex  = Mutex.new
      client = Particular.new tty
      server = WEBrick::HTTPServer.new(:Port => 8000, :DocumentRoot => root)
      server.mount "/samples", SampleServlet, client, mutex
      trap "INT" do server.shutdown end
      server.start
    end
  end
end

if __FILE__ == $0
  Particular::WebServer.start ARGV[0]
  # require 'csv'
  # client = Particular.new ARGV[0]
  # CSV do |csv|
  #   csv << Particular::Sample.members
  #   while data = client.read
  #     csv << data.to_a
  #     $stdout.flush
  #   end
  # end
end
