require 'sinatra'
require 'sinatra/base'
require 'sinatra/json'
require 'mongoid'
require 'aws-sdk-s3'
require 'json'

Mongoid.load! './mongoid.yml'

class Map
  include Mongoid::Document
  include Mongoid::Timestamps

  embeds_many :pins

  field :name, type: String
  field :key, type: String
end

class Pin
  include Mongoid::Document
  include Mongoid::Timestamps

  embedded_in :map
  embeds_many :bits

  field :x, type: Float
  field :y, type: Float
  field :key, type: String
  field :name, type: String
end

class Bit
  include Mongoid::Document
  include Mongoid::Timestamps

  embedded_in :pin

  field :key, type: String
  field :name, type: String
  field :comment, type: String
end

class App < Sinatra::Base
  def bucket
    @bucket ||= Aws::S3::Resource.new(region: 'us-east-2').bucket('smistore')
  end

  get '/' do
    redirect "/maps"
  end

  get '/maps/new' do
    erb :'maps/new'
  end

  get '/maps/:map_id' do
    @map = Map.find params[:map_id]
    
    puts @env["HTTP_X_REQUESTED_WITH"]
    
    if request.xhr?
      json map: @map
    else
      signer = Aws::S3::Presigner.new
      @url = signer.presigned_url :get_object, bucket: "smistore", key: @map.key
      scheme = request.scheme == "http" ? "ws" : "wss"
      @ws_url = "#{scheme}://#{request.host}:#{request.port}"
      erb :'maps/show'
    end
  end

  get '/maps' do
    @maps = Map.all
    erb :'maps/index'
  end

  post '/maps' do
    filename = params[:map][:filename]
    file = params[:map][:tempfile]

    obj = bucket.object "#{filename}"

    # don't overwrite dups

    if obj.upload_file file
      @map = Map.create(name: params[:name], key: obj.key, pins: [])

      redirect "/maps/#{@map.id}"
    else
      @status = 500
      @error = 'there was a problem uploading the file'
    end
  end

  post '/maps/:map_id/pins' do
    map = Map.find params[:map_id]

    pin = begin
            map.pins.find_by key: params[:key]
          rescue
            map.pins.new key: params[:key], name: params[:name]
          end

    if params[:x] && params[:y]
      pin.update_attributes x: params[:x], y: params[:y]
    elsif params[:comment]
      pin.bits.create name: pin.name, key: pin.key, comment: params[:comment]
    end

    json map: map, pin: pin
  end
end
