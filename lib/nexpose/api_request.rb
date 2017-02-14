module Nexpose
  class APIRequest
    include XMLUtils

    attr_reader :http
    attr_reader :uri
    attr_reader :headers

    attr_reader :req
    attr_reader :res
    attr_reader :sid
    attr_reader :success

    attr_reader :error
    attr_reader :trace

    attr_reader :raw_response
    attr_reader :raw_response_data

    attr_reader :trust_store

    def initialize(req, url, api_version = '1.1', trust_store = nil)
      @url = url
      @req = req
      @api_version = api_version
      @url = @url.sub('API_VERSION', @api_version)
      @trust_store = trust_store
      prepare_http_client
    end

    def prepare_http_client
      @uri = URI.parse(@url)
      @http = Net::HTTP.new(@uri.host, @uri.port)
      @http.use_ssl = true
      #
      # XXX: This is obviously a security issue, however, we handle this at the client level by forcing
      #      a confirmation when the nexpose host is not localhost. In a perfect world, we would present
      #      the server signature before accepting it, but this requires either a direct callback inside
      #      of this module back to whatever UI, or opens a race condition between accept and attempt.
      if @trust_store.nil?
        @http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        @http.cert_store = @trust_store
      end
      @headers = {'Content-Type' => 'text/xml'}
      @success = false
    end

    def execute(options = {})
      @conn_tries = 0

      begin
        prepare_http_client
        @http.read_timeout = options[:timeout] if options.key? :timeout
        @raw_response = @http.post(@uri.path, @req, @headers)
        @raw_response_data = @raw_response.read_body

        # Allow the :raw keyword to bypass XML parsing.
        if options[:raw]
          if raw_response_data =~ /success="1"/
            @success = true
          else
            @success = false
            @error = "User requested raw XML response. Not parsing failures."
          end
        else
          @res = parse_xml(@raw_response_data)

          unless @res.root
            @error = 'Nexpose service returned invalid XML.'
            return @sid
          end

          @sid = attributes['session-id']

          if (attributes['success'] and attributes['success'].to_i == 1)
            @success = true
          elsif @api_version =~ /1.2/ and @res and (@res.get_elements '//Exception').count < 1
            @success = true
          else
            @success = false
            if @api_version =~ /1.2/
              @res.elements.each('//Exception/Message') do |message|
              @error = message.text.sub(/.*Exception: */, '')
              end
            @res.elements.each('//Exception/Stacktrace') do |stacktrace|
              @trace = stacktrace.text
            end
            else
              @res.elements.each('//message') do |message|
                @error = message.text.sub(/.*Exception: */, '')
              end
              @res.elements.each('//stacktrace') do |stacktrace|
                @trace = stacktrace.text
              end
            end
          end
        end
        # This is a hack to handle corner cases where a heavily loaded Nexpose instance
        # drops our HTTP connection before processing. We try 5 times to establish a
        # connection in these situations. The actual exception occurs in the Ruby
        # http library, which is why we use such generic error classes.
      rescue OpenSSL::SSL::SSLError => e
        if @conn_tries < 5
          @conn_tries += 1
          retry
        end
      rescue ::ArgumentError, ::NoMethodError => e
        if @conn_tries < 5
          @conn_tries += 1
          retry
        end
      rescue ::Timeout::Error
        if @conn_tries < 5
          @conn_tries += 1
          # If an explicit timeout is set, don't retry.
          retry unless options.key? :timeout
        end
        @error = "Nexpose did not respond within #{@http.read_timeout} seconds."
      rescue ::Errno::EHOSTUNREACH, ::Errno::ENETDOWN, ::Errno::ENETUNREACH, ::Errno::ENETRESET, ::Errno::EHOSTDOWN, ::Errno::EACCES, ::Errno::EINVAL, ::Errno::EADDRNOTAVAIL
        @error = 'Nexpose host is unreachable.'
        # Handle console-level interrupts
      rescue ::Interrupt
        @error = 'Received a user interrupt.'
      rescue ::Errno::ECONNRESET, ::Errno::ECONNREFUSED, ::Errno::ENOTCONN, ::Errno::ECONNABORTED
        @error = 'Nexpose service is not available.'
      rescue ::REXML::ParseException => exc
        @error = "Error parsing response: #{exc.message}"
      end

      if !(@success or @error)
        @error = "Nexpose service returned an unrecognized response: #{@raw_response_data.inspect}"
      end

      @sid
    end

    def attributes(*args)
      return if not @res.root
      @res.root.attributes(*args)
    end

    def self.execute(url, req, api_version = '1.1', options = {}, trust_store = nil)
      obj = self.new(req.to_s, url, api_version, trust_store)
      obj.execute(options)
      raise APIError.new(obj, "Action failed: #{obj.error}") unless obj.success
      obj
    end
  end
end
