#!/usr/bin/env ruby
# Nostr Relay for Ruby 3.0

# Force immediate stdout/stderr flushing for container logs
$stdout.sync = true
$stderr.sync = true

require 'logger'

# Initialize logger
LOGGER = Logger.new($stdout)
LOGGER.level = Logger::INFO
LOGGER.formatter = proc do |severity, datetime, progname, msg|
  "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
end

LOGGER.info "Starting Ruby Nostr Relay..."
LOGGER.info "Ruby version: #{RUBY_VERSION}"

# Suppress IO::Buffer warning from async-websocket
$VERBOSE = nil

require 'bundler/setup'

LOGGER.info "Loading dependencies..."

require 'async'
require 'async/websocket/response'
require 'protocol/websocket/connection'
require 'protocol/websocket/framer'
require 'async/http/endpoint'
require 'protocol/http/response'
require 'sequel'
require 'json'
require 'digest'
require 'schnorr'
require 'mini_mime'

LOGGER.info "Dependencies loaded successfully"

# PostgreSQL Database Setup
LOGGER.info "Initializing database connection..."
begin
  db_url = ENV['DATABASE_URL']
  if db_url && !db_url.empty?
    DB = Sequel.connect(db_url)
    DB.extension :pg_json

    LOGGER.info "Connected to database: custom"

    # Create tags_to_tagvalues function if not exists
    DB.run <<~SQL
      CREATE OR REPLACE FUNCTION tags_to_tagvalues(jsonb) RETURNS text[]
      AS 'SELECT array_agg(t->>1) FROM (SELECT jsonb_array_elements($1) AS t)s WHERE length(t->>0) = 1;'
      LANGUAGE SQL
      IMMUTABLE
      RETURNS NULL ON NULL INPUT;
    SQL

    LOGGER.info "Database function tags_to_tagvalues created/verified"

    # Create event table if not exists
    unless DB.table_exists?(:event)
      LOGGER.info "Creating event table..."
      DB.run <<~SQL
        CREATE TABLE event (
          id text NOT NULL,
          pubkey text NOT NULL,
          created_at integer NOT NULL,
          kind integer NOT NULL,
          tags jsonb NOT NULL,
          content text NOT NULL,
          sig text NOT NULL,
          tagvalues text[] GENERATED ALWAYS AS (tags_to_tagvalues(tags)) STORED
        );
      SQL

      LOGGER.info "Creating indexes..."
      # Create indexes
      DB.run "CREATE UNIQUE INDEX IF NOT EXISTS ididx ON event USING btree (id text_pattern_ops);"
      DB.run "CREATE INDEX IF NOT EXISTS pubkeyprefix ON event USING btree (pubkey text_pattern_ops);"
      DB.run "CREATE INDEX IF NOT EXISTS timeidx ON event (created_at DESC);"
      DB.run "CREATE INDEX IF NOT EXISTS kindidx ON event (kind);"
      DB.run "CREATE INDEX IF NOT EXISTS kindtimeidx ON event(kind, created_at DESC);"
      DB.run "CREATE INDEX IF NOT EXISTS arbitrarytagvalues ON event USING gin (tagvalues);"

      LOGGER.info "Database table and indexes created successfully"
    else
      LOGGER.info "Database table 'event' already exists"
    end

    LOGGER.info "Database setup completed successfully"
  else
    LOGGER.info "No DATABASE_URL provided, starting without database support"
    DB = nil
  end
rescue => e
  LOGGER.error "Database connection failed: #{e.class} - #{e.message}"
  LOGGER.error e.backtrace.first(5).join("\n") if e.backtrace
  LOGGER.warn "Server will start without database support"
  DB = nil
end

# Nostr Relay Implementation
class NostrRelay
  # Global connection management for broadcasting
  @@connections = []
  @@connections_mutex = Mutex.new

  # Track vanished pubkeys to prevent re-broadcasting
  @@vanished_pubkeys = {}
  @@vanished_mutex = Mutex.new

  def call(request)
    # Check for WebSocket connection
    if request.respond_to?(:protocol) && request.protocol&.include?('websocket')
      return handle_websocket(request)
    end

    Protocol::HTTP::Response[404, {}, ["Not Found"]]
  rescue => e
    LOGGER.error "Request handling error: #{e.class} - #{e.message}"
    LOGGER.error e.backtrace.first(3).join("\n") if e.backtrace
    Protocol::HTTP::Response[400, {}, ["Bad request: #{e.message}"]]
  end

  def handle_websocket(request)
    Async::WebSocket::Response.for(request) do |stream|
      # Wrap stream with Protocol::WebSocket::Connection
      framer = Protocol::WebSocket::Framer.new(stream)
      connection = Protocol::WebSocket::Connection.new(framer)

      # Register this connection
      client = {connection: connection, subscriptions: {}}
      @@connections_mutex.synchronize { @@connections << client }

      begin
        #connection.write(["NOTICE", "Nostr Relay - Connected"].to_json)
        #connection.flush

        begin
          loop do
            message = connection.read
            break unless message

            # Extract text content from message object
            text = message.to_str

            begin
              cmd, *args = JSON.parse(text)
              LOGGER.info "Received: #{text}"
              case cmd
              when "EVENT"
                event = args[0]
                # Handle event and send OK response
                success, message = handle_event(event)
                if success
                  connection.write(["OK", event["id"], true, ""].to_json)
                else
                  connection.write(["OK", event["id"], false, message || "rejected: invalid event"].to_json)
                end
                connection.flush
              when "COUNT"
                # Store subscription filters for COUNT requests
                client[:subscriptions][args[0]] = args[1..-1]
                send_count(connection, args[0], args[1..-1])
              when "REQ"
                # Store subscription filters for REQ requests
                client[:subscriptions][args[0]] = args[1..-1]
                send_history(connection, args[0], args[1..-1])
              when "CLOSE"
                client[:subscriptions].delete(args[0])
              end
            rescue JSON::ParserError
              LOGGER.warn "Failed to parse JSON: #{text}"
              connection.write(["NOTICE", "error: invalid JSON"].to_json) rescue nil
              connection.flush rescue nil
            rescue => e
              error_msg = e.message.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
              LOGGER.error "Error processing message: #{e.class} - #{e.message}"
              LOGGER.error e.backtrace.first(3).join("\n") if e.backtrace
              connection.write(["NOTICE", "error: #{error_msg}"].to_json) rescue nil
              connection.flush rescue nil
            end
          end
        rescue EOFError, Errno::EPIPE, Errno::ECONNRESET, Protocol::WebSocket::ProtocolError => e
          LOGGER.info "Client disconnected: #{e.class} - #{e.message}"
        rescue => e
          LOGGER.error "WebSocket read loop error: #{e.class} - #{e.message}"
          LOGGER.error e.backtrace.first(3).join("\n") if e.backtrace
        end
      ensure
        # Remove this connection from global list
        @@connections_mutex.synchronize { @@connections.delete(client) }
      end
    end
  end

  private

  def verify_event(event)
    # Verify event structure
    return false unless event.is_a?(Hash)
    return false unless event["id"] && event["pubkey"] && event["sig"]
    return false unless event["created_at"] && event["kind"]
    return false unless event["tags"].is_a?(Array)
    return false unless event["content"]

    # NIP-22: Timestamp validation
    # Reject events with timestamps too far in future or past
    now = Time.now.to_i
    created_at = event["created_at"]

    # Allow events up to 15 minutes in the future (clock skew)
    max_future = now + (15 * 60)
    # Allow events up to 3 years in the past
    min_past = now - (3 * 365 * 24 * 60 * 60)

    return false if created_at > max_future
    return false if created_at < min_past

    # Serialize event for ID calculation (NIP-01)
    serialized = JSON.generate([
      0,
      event["pubkey"],
      event["created_at"],
      event["kind"],
      event["tags"],
      event["content"]
    ])

    # Calculate and verify event ID
    calculated_id = Digest::SHA256.hexdigest(serialized)
    return false unless calculated_id == event["id"]

    # Verify schnorr signature using bip-schnorr gem
    begin
      message = [event["id"]].pack('H*')
      public_key = [event["pubkey"]].pack('H*')
      signature = [event["sig"]].pack('H*')

      Schnorr.valid_sig?(message, public_key, signature)
    rescue => e
      LOGGER.warn "Schnorr signature verification failed: #{e.message}"
      false
    end
  end

  def handle_event(event)
    # Verify event signature (ID verification only - catches malformed events)
    valid = verify_event(event)
    unless valid
      return [false, "invalid: event signature verification failed"]
    end

    # NIP-70: Reject protected events (events with "-" tag)
    # Protected events can only be published by the author after AUTH
    # Since we don't implement AUTH yet, reject all protected events
    protected_tag = event["tags"].find { |t| t.is_a?(Array) && t[0] == "-" }
    if protected_tag
      # Reject protected events
      return [false, "auth-required: this event may only be published by its author"]
    end

    # NIP-40: Filter out expired events
    expiration_tag = event["tags"].find { |t| t.is_a?(Array) && t[0] == "expiration" }
    if expiration_tag && expiration_tag[1]
      expiration_time = expiration_tag[1].to_i
      if Time.now.to_i >= expiration_time
        # Event has expired, don't broadcast or save
        return [false, "invalid: event has expired"]
      end
    end

    # Handle kind 62 (request to vanish) - NIP-62
    if event["kind"] == 62 && DB
      # Check if this relay is targeted
      relay_tags = event["tags"].select { |t| t.is_a?(Array) && t[0] == "relay" }
      current_relay_url = ENV['RELAY_URL'] || "ws://localhost:8080"

      is_targeted = relay_tags.any? do |tag|
        tag[1] == "ALL_RELAYS" || tag[1] == current_relay_url
      end

      if is_targeted
        # Delete all events from this pubkey created before the vanish request
        DB[:event].where(pubkey: event["pubkey"])
          .where { created_at <= event["created_at"] }
          .delete

        # Mark this pubkey as vanished to prevent re-broadcasting
        @@vanished_mutex.synchronize do
          @@vanished_pubkeys[event["pubkey"]] = event["created_at"]
        end

        # Save the vanish request itself for bookkeeping
        DB[:event].insert(
          id: event["id"],
          pubkey: event["pubkey"],
          kind: event["kind"],
          created_at: event["created_at"],
          tags: Sequel.pg_jsonb(event["tags"]),
          content: event["content"],
          sig: event["sig"]
        )
      end
      # Don't broadcast vanish requests
      return [true, ""]
    end

    # Prevent re-broadcasting vanished events
    @@vanished_mutex.synchronize do
      vanish_time = @@vanished_pubkeys[event["pubkey"]]
      if vanish_time && event["created_at"] <= vanish_time
        # Reject events from vanished pubkeys created before vanish request
        return [false, "blocked: author has requested to vanish"]
      end
    end

    kind = event["kind"]

    # Save to database if connected
    if DB
      begin
        # Skip if event already exists
        if DB[:event][:id => event["id"]]
          return [true, ""]
        end

        if kind == 5
          # Deletion events (NIP-09)
          # Extract kind filter from "k" tags if present
          k_tags = event["tags"].select { |t| t.is_a?(Array) && t[0] == "k" && t[1] }
          kind_filter = k_tags.map { |t| t[1].to_i } unless k_tags.empty?

          event["tags"].each do |tag|
            if tag.is_a?(Array) && tag[0] == "e" && tag[1]
              event_id = tag[1]

              target = DB[:event].where(id: event_id).first
              if target.nil?
                LOGGER.info "Deletion: target event #{event_id} not found"
                next
              end

              LOGGER.info "Deletion: found target event #{event_id}, kind=#{target[:kind]}, pubkey=#{target[:pubkey]}, deletion_pubkey=#{event["pubkey"]}"

              # Apply kind filter if specified
              if kind_filter && !kind_filter.include?(target[:kind])
                LOGGER.info "Deletion: kind filter mismatch (filter=#{kind_filter}, target_kind=#{target[:kind]})"
                next
              end

              if target[:kind] == 1059
                # Only delete events from the same author
                deleted = DB[:event].where(id: event_id, kind: 1059)
                  .where(Sequel.lit("tags @> ?", Sequel.pg_jsonb([["p", event["pubkey"]]])))
                  .delete
                LOGGER.info "Deletion: deleted #{deleted} kind 1059 events"
              else
                # Only delete events from the same author
                deleted = DB[:event].where(id: event_id, pubkey: event["pubkey"]).delete
                LOGGER.info "Deletion: deleted #{deleted} events (pubkey match required)"
              end
            end
          end
        elsif kind == 0 || kind == 3 || (10000 <= kind && kind < 20000)
          # Regular replaceable: Replace older events with same kind and pubkey
          existing = DB[:event].where(kind: kind, pubkey: event["pubkey"]).first
          if existing
            # Only replace if new event is newer
            if event["created_at"] > existing[:created_at]
              DB[:event].where(kind: kind, pubkey: event["pubkey"]).delete
            else
              # Reject older event
              return [false, "duplicate: newer event already exists"]
            end
          end
        elsif 30000 <= kind && kind < 40000
          # Parameterized replaceable: Replace events with same kind, pubkey, and "d" tag
          d_tag = event["tags"].find { |t| t.is_a?(Array) && t[0] == "d" }
          d_value = d_tag&.[](1) || ""

          existing = DB[:event].where(kind: kind, pubkey: event["pubkey"])
            .where(Sequel.lit("tags @> ?", Sequel.pg_jsonb([["d", d_value]])))
            .first

          if existing
            # Only replace if new event is newer
            if event["created_at"] > existing[:created_at]
              DB[:event].where(id: existing[:id]).delete
            else
              # Reject older event
              return [false, "duplicate: newer event already exists"]
            end
          end
        end

        unless kind == 5 || (20000 <= kind && kind < 30000)
          DB[:event].insert(
            id: event["id"],
            pubkey: event["pubkey"],
            kind: event["kind"],
            created_at: event["created_at"],
            tags: Sequel.pg_jsonb(event["tags"]),
            content: event["content"],
            sig: event["sig"]
          )
        end
      rescue => e
        LOGGER.error "Database error while saving event: #{e.class} - #{e.message}"
        LOGGER.error e.backtrace.first(3).join("\n") if e.backtrace
        # Continue to broadcast even if save failed
      end
    end

    # Broadcast to all connected clients with matching subscriptions
    @@connections_mutex.synchronize do
      @@connections.each do |client|
        begin
          client[:subscriptions].each do |sub_id, filters|
            if match_filters?(event, filters)
              client[:connection].write(["EVENT", sub_id, event].to_json)
              client[:connection].flush
            end
          end
        rescue => e
          # Ignore errors sending to disconnected clients
          LOGGER.warn "Error broadcasting event to client: #{e.message}"
        end
      end
    end

    # Return success
    [true, ""]
  end

  def escape_like(keywords)
    '%' + keywords
      .gsub(/[_%\\]/) { |m| "\\#{m}" }
      .split
      .join('%') + '%'
  end

  # Common logic for sending events (used by COUNT and REQ)
  def send_events(conn, sub_id, filters)
    unless DB
      conn.write(["EOSE", sub_id].to_json)
      conn.flush
      return
    end

    ds = DB[:event].order(Sequel.desc(:created_at))

    # Apply filters
    filters.each do |f|
      ds = ds.where(Sequel.like(:id, "#{f['ids']&.first}%")) if f['ids']&.first
      ds = ds.where(pubkey: f['authors']) if f['authors']
      ds = ds.where(kind: f['kinds']) if f['kinds']
      ds = ds.where{created_at >= f['since']} if f['since']
      ds = ds.where{created_at <= f['until']} if f['until']
      if f['search']
        s = escape_like(f['search'])
        ds = ds.where{Sequel.like(:content, s)}
      end

      # NIP-12: Generic tag queries (#e, #p, etc)
      f.each do |key, values|
        if key.start_with?('#') && values.is_a?(Array)
          tag_name = key[1..-1]
          # Use the tagvalues generated column for efficient tag searching
          ds = ds.where(Sequel.lit("tagvalues && ARRAY[?]::text[]", values))
        end
      end

      # Use limit from filter if present, otherwise max 500
      limit = f['limit'] ? [f['limit'], 500].min : 500
      ds = ds.limit(limit)
    end

    count = 0
    ds.each do |row|
      # Convert database row to Nostr event format
      event = {
        "id" => row[:id],
        "pubkey" => row[:pubkey],
        "created_at" => row[:created_at],
        "kind" => row[:kind],
        "tags" => row[:tags],
        "content" => row[:content],
        "sig" => row[:sig]
      }

      # NIP-40: Skip expired events
      expiration_tag = event["tags"].find { |t| t.is_a?(Array) && t[0] == "expiration" }
      if expiration_tag && expiration_tag[1]
        expiration_time = expiration_tag[1].to_i
        next if Time.now.to_i >= expiration_time
      end

      conn.write(["EVENT", sub_id, event].to_json)
      conn.flush
      count += 1
    end

    # For COUNT, send the count instead of EOSE
    if filters.any? { |f| f.key?("count") }
      conn.write(["COUNT", sub_id, {"count" => count}].to_json)
    end

    conn.write(["EOSE", sub_id].to_json)
    conn.flush
  end

  def send_count(conn, sub_id, filters)
    send_events(conn, sub_id, filters)
  end

  def send_history(conn, sub_id, filters)
    send_events(conn, sub_id, filters)
  end

  def match_filters?(event, filters)
    filters.any? do |f|
      # Basic filters
      matches = true
      matches &&= f['ids'].any? { |p| event["id"].start_with?(p) } if f['ids']
      matches &&= f['authors'].include?(event["pubkey"]) if f['authors']
      matches &&= f['kinds'].include?(event["kind"]) if f['kinds']
      matches &&= event["created_at"] >= f['since'] if f['since']
      matches &&= event["created_at"] <= f['until'] if f['until']

      # NIP-12: Generic tag queries (#e, #p, etc)
      f.each do |key, values|
        if key.start_with?('#') && values.is_a?(Array)
          tag_name = key[1..-1]
          # Check if any of the event's tags match
          tag_values = event["tags"].select { |t| t[0] == tag_name }.map { |t| t[1] }
          matches &&= values.any? { |v| tag_values.include?(v) }
        end
      end

      matches
    end
  end
end

# NIP-11: Relay Information Document middleware
class RelayInfo
  def initialize(app)
    @app = app
  end

  def call(request)
    # Return JSON metadata for HTTP GET requests with Accept: application/nostr+json
    if request.method == "GET" &&
       request.headers['accept']&.include?('application/nostr+json')
      relay_info = {
        name: ENV['RELAY_NAME'] || "Ruby Nostr Relay",
        description: ENV['RELAY_DESCRIPTION'] || "A lightweight Nostr relay implementation in Ruby",
        pubkey: ENV['RELAY_PUBKEY'] || "",
        contact: ENV['RELAY_CONTACT'] || "",
        icon: ENV['RELAY_ICON'] || "",
        # Updated supported_nips based on common implementations and NIPs handled
        supported_nips: [1, 2, 4, 9, 11, 12, 15, 16, 20, 22, 28, 33, 40, 50, 62, 70],
        software: "https://github.com/mattn/ruby-nostr-relay",
        version: "1.0.0",
        limitation: {
          # Updated limitations based on typical relay configurations and NIP-11 spec
          max_message_length: 65536,
          max_subscriptions: 20, # Example value, can be configured
          max_filters: 10,       # Example value, can be configured
          max_limit: 500,        # Example value, can be configured
          max_subid_length: 100,
          min_prefix: 4,
          max_event_tags: 2000,
          max_content_length: 65536,
          min_pow_difficulty: 0, # Currently not enforced
          auth_required: false,  # Currently not implemented
          payment_required: false # Currently not implemented
        }
      }

      return Protocol::HTTP::Response[200,
        {
          'content-type' => 'application/json',
          'access-control-allow-origin' => '*',
          'access-control-allow-headers' => 'Content-Type, Accept',
          'access-control-allow-methods' => 'GET'
        },
        [relay_info.to_json]]
    end

    @app.call(request)
  end
end

class StaticFiles
  def initialize(app, root: "public")
    @app = app
    @root = File.expand_path(root)
  end

  def call(request)
    # Avoid processing WebSocket requests as static files
    if request.respond_to?(:protocol) && request.protocol&.include?('websocket')
      return @app.call(request)
    end

    if request.path == "/"
      request.path = "/index.html"
    end
    path = File.expand_path(File.join(@root, request.path))

    # Prevent directory traversal attacks
    unless path.start_with?(@root)
      LOGGER.warn "Attempted directory traversal: #{request.path}"
      return Protocol::HTTP::Response[403, {}, ["Forbidden"]]
    end

    if File.file?(path)
      headers = {
        "content-length" => File.size(path).to_s,
        "content-type" => MiniMime.lookup_by_filename(path)&.content_type || "application/octet-stream",
      }
      return Protocol::HTTP::Response[200, headers, File.open(path, "rb")]
    end

    Protocol::HTTP::Response[404, {}, ["Not Found"]]
  end
end

# Server startup
if $0 == __FILE__
  require 'falcon/server'
  require 'async/reactor'

  relay = NostrRelay.new
  static_files = StaticFiles.new(relay, root: "public")
  relay_info = RelayInfo.new(static_files)
  endpoint = Async::HTTP::Endpoint.parse("http://0.0.0.0:8080")

  LOGGER.info "Nostr Relay starting on #{endpoint.url}"

  Async do
    server = Falcon::Server.new(relay_info, endpoint)
    server.run
  end
end
