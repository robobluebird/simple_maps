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

  embedded_in :maps

  field :x, type: Float
  field :y, type: Float
  field :guid, type: String
  field :name, type: String
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
    @map = Map.find(params[:map_id])
    signer = Aws::S3::Presigner.new
    @url = signer.presigned_url(:get_object, bucket: "smistore", key: @map.key)
    erb :'maps/show'
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
      @map = Map.create(name: params[:name], key: obj.key)

      redirect "/maps/#{@map.id}"
    else
      @status = 500
      @error = 'there was a problem uploading the file'
    end
  end

  post '/maps/:map_id/pins' do
    map = Map.find params[:map_id]

    pin = begin
            map.pins.find_by guid: params[:guid]
          rescue
            map.pins.new guid: params[:guid], name: params[:name]
          end

    pin.x = params[:x]
    pin.y = params[:y]
    pin.save

    json pin: pin
  end
end
