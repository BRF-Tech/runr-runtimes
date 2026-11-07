# frozen_string_literal: true

# RunR Ruby runtime: serves the RunR HTTP contract on $PORT and calls the function's handler for
# every request, or (RUNR_MODE=schedule) calls it once, prints the result and exits.
#
# The handler is the top-level method RUNR_HANDLER (default "handler") of RUNR_FILENAME in
# /app/code: def handler(event, context), def handler(event) or, as on AWS Lambda,
# def handler(event:, context:). event is the request body parsed as JSON (string keys), else
# {"body" => body}; context holds "method", "path" and "headers" (lower-case names). A Hash
# result with statusCode / headers / body (symbol or string keys) is a response envelope;
# anything else is the body (JSON unless it is a string with another Content-Type). A function
# built with a Gemfile has its gems in /app/gems: the standalone setup of runr-bundle
# (RUNR_BUNDLE_SETUP) puts them on the load path first, else Bundler (BUNDLE_GEMFILE).

require "json"
require "socket"
require "io/wait"

$stdout.sync = true
$stderr.sync = true

module Runr
  CODE_DIR = "/app/code"
  IDLE_SECONDS = 75
  CORS = {
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    "Access-Control-Allow-Headers" => "Content-Type, Authorization",
    "Access-Control-Max-Age" => "86400",
  }.freeze
  REASONS = {
    200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content", 301 => "Moved Permanently",
    302 => "Found", 304 => "Not Modified", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
    404 => "Not Found", 405 => "Method Not Allowed", 409 => "Conflict", 413 => "Payload Too Large",
    422 => "Unprocessable Entity", 429 => "Too Many Requests", 500 => "Internal Server Error",
    502 => "Bad Gateway", 503 => "Service Unavailable", 504 => "Gateway Timeout",
  }.freeze

  module_function

  def env(name, fallback)
    value = ENV[name]
    value.nil? || value.empty? ? fallback : value
  end

  def load_handler
    setup = ENV["RUNR_BUNDLE_SETUP"]
    gemfile = ENV["BUNDLE_GEMFILE"]
    if setup && File.exist?(setup)
      require setup
    elsif gemfile && File.exist?(gemfile)
      require "bundler/setup"
    end

    name = env("RUNR_HANDLER", "handler")
    file = env("RUNR_FILENAME", "main.rb")
    $LOAD_PATH.unshift(CODE_DIR)
    require File.join(CODE_DIR, file)

    main = TOPLEVEL_BINDING.receiver
    unless main.respond_to?(name, true)
      warn "Error: handler '#{name}' not found in #{file}"
      exit 1
    end
    main.method(name)
  end

  # handler(event, context), handler(event), handler, or handler(event:, context:)
  def call(handler, event, context)
    params = handler.parameters
    if params.any? { |type, _| type == :keyreq || type == :key }
      keys = params.select { |type, _| type == :keyreq || type == :key }.map(&:last)
      kwargs = {}
      kwargs[:event] = event if keys.include?(:event)
      kwargs[:context] = context if keys.include?(:context)
      return handler.call(**kwargs)
    end
    positional = params.count { |type, _| type == :req || type == :opt }
    rest = params.any? { |type, _| type == :rest }
    args = [event, context]
    handler.call(*args.first(rest ? 2 : [positional, 2].min))
  end

  def field(hash, key)
    return hash[key] if hash.key?(key)

    hash[key.to_sym]
  end

  def field?(hash, key)
    hash.key?(key) || hash.key?(key.to_sym)
  end

  def event_of(body)
    return {} if body.empty?

    JSON.parse(body)
  rescue JSON::ParserError
    { "body" => body }
  end

  # [status, headers, payload] of a handler's result
  def response_of(result)
    status = 200
    custom = {}
    body = result
    if result.is_a?(Hash)
      code = field(result, "statusCode")
      status = code.to_i if code.is_a?(Numeric)
      custom = field(result, "headers") if field(result, "headers").is_a?(Hash)
      body = field(result, "body") if field?(result, "body")
    end

    # user headers override the defaults, whatever their case
    headers = { "Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json" }
    custom.each do |name, value|
      headers.delete_if { |k, _| k.casecmp?(name.to_s) }
      headers[name.to_s] = value.to_s
    end
    content_type = headers.find { |k, _| k.casecmp?("Content-Type") }&.last.to_s
    payload = body.is_a?(String) && !content_type.include?("application/json") ? body : JSON.generate(body)
    status = 500 if status < 100 || status > 999
    [status, headers, payload]
  end

  def dispatch(handler, method, path, headers, body)
    # Knative probe: not passed to the handler
    return [200, {}, "ok"] if headers.key?("k-network-probe") || headers.key?("k-kubelet-probe")
    # CORS preflight
    return [204, CORS, ""] if method == "OPTIONS"

    context = { "method" => method, "path" => path, "headers" => headers }
    begin
      response_of(call(handler, event_of(body), context))
    rescue Exception => e # rubocop:disable Lint/RescueException
      warn "#{e.class}: #{e.message}\n#{(e.backtrace || []).join("\n")}"
      [500, { "Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json" },
       JSON.generate({ "error" => "#{e.class}: #{e.message}" })]
    end
  end

  def read_body(sock, headers)
    if (length = headers["content-length"])
      return sock.read(length.to_i) || ""
    end
    return "" unless headers["transfer-encoding"].to_s.downcase.include?("chunked")

    body = +""
    loop do
      size = sock.gets("\r\n").to_s.split(";").first.to_s.strip.to_i(16)
      if size.zero?
        nil while (line = sock.gets("\r\n")) && line != "\r\n"
        return body
      end
      body << sock.read(size).to_s
      sock.read(2)
    end
  end

  # One connection: its requests one after the other (HTTP/1.1 keep-alive)
  def serve(sock, handler)
    loop do
      break unless sock.wait_readable(IDLE_SECONDS)

      line = sock.gets("\r\n")
      break if line.nil?

      line = line.chomp
      next if line.empty?

      method, path, version = line.split(" ", 3)
      headers = {}
      while (header = sock.gets("\r\n"))
        header = header.chomp
        break if header.empty?

        name, value = header.split(":", 2)
        next if value.nil?

        key = name.strip.downcase
        value = value.strip
        headers[key] = headers.key?(key) ? "#{headers[key]}, #{value}" : value
      end
      body = read_body(sock, headers).dup.force_encoding(Encoding::UTF_8).scrub

      status, out, payload = dispatch(handler, method, path.to_s, headers, body)
      connection = headers["connection"].to_s.downcase
      keep = version.to_s.strip == "HTTP/1.1" ? connection != "close" : connection == "keep-alive"

      bytes = payload.to_s.b
      response = +"HTTP/1.1 #{status} #{REASONS.fetch(status, 'Status')}\r\n"
      out.each { |name, value| response << "#{name}: #{value}\r\n" }
      response << "Content-Length: #{bytes.bytesize}\r\n" unless status == 204 || status == 304
      response << "Connection: #{keep ? 'keep-alive' : 'close'}\r\n\r\n"
      response = response.b
      response << bytes unless status == 204 || status == 304 || method == "HEAD"
      sock.write(response)
      puts "[runr] #{method} #{path} #{status}"
      break unless keep
    end
  rescue IOError, SystemCallError
    # the client went away
  ensure
    sock.close unless sock.closed?
  end

  def schedule(handler)
    result = call(handler, { "trigger" => "schedule" }, { "mode" => "schedule" })
    puts(result.is_a?(Hash) || result.is_a?(Array) ? JSON.generate(result) : result.to_s)
    exit 0
  rescue SystemExit
    raise
  rescue Exception => e # rubocop:disable Lint/RescueException
    warn "Error: #{e.class}: #{e.message}\n#{(e.backtrace || []).join("\n")}"
    exit 1
  end

  def run
    handler = load_handler
    schedule(handler) if env("RUNR_MODE", "http") == "schedule"

    port = Integer(env("PORT", "8080"))
    server = TCPServer.new("0.0.0.0", port)
    puts "RunR Ruby runtime listening on :#{port}"
    %w[TERM INT].each { |signal| trap(signal) { exit 0 } }
    loop do
      sock = server.accept
      Thread.new(sock) { |s| serve(s, handler) }
    end
  end
end

Runr.run
