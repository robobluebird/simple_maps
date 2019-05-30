require 'faye/websocket'
require 'json'

module Rack
  class Lint
    def call(env = nil)
      @app.call(env)
    end
  end
end

class Rack::Lint::HijackWrapper
  def to_int
    @io.to_i
  end
end

class Ws
  def initialize(app)
    @app     = app
    @clients = []
  end

  def call(env)
    if Faye::WebSocket.websocket?(env)
      ws = Faye::WebSocket.new env

      ws.on :open do |event|
        p [:open, ws.object_id]
        @clients << ws
      end

      ws.on :message do |event|
        data = JSON.parse event.data, symbolize_names: true

        if data[:id] && data[:key]
          map = Map.find data[:id]
          data = { map: map }
          @clients.each { |client| client.send data.to_json }
        end
      end

      ws.on :close do |event|
        p [:close, ws.object_id, event.code, event.reason]
        @clients.delete(ws)
        ws = nil
      end

      ws.rack_response
    else
      @app.call(env)
    end
  end
end
