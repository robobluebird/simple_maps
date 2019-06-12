require "sinatra"
require "sinatra/base"
require "sinatra/json"
require "mongoid"
require "aws-sdk-s3"
require "json"

module Mongoid
 module Document
   def as_json(options={})
     attrs = super(options)
     attrs["id"] = attrs["_id"].to_s
     attrs
   end
 end
end

Mongoid.load! "./mongoid.yml"

class Location
  include Mongoid::Document
  include Mongoid::Timestamps

  embeds_many :maps
  belongs_to :pin, optional: true

  field :name, type: String
  field :key, type: String
end

class Map
  include Mongoid::Document
  include Mongoid::Timestamps

  embedded_in :location
  embeds_many :pins

  field :key, type: String
end

class Pin
  include Mongoid::Document
  include Mongoid::Timestamps

  embedded_in :map
  embeds_many :bits
  has_one :location

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
    @bucket ||= Aws::S3::Resource.new(region: "us-east-2").bucket("smistore")
  end

  get "/" do
    redirect "/locations"
  end
  
  # list 'em
  
  get "/locations" do
    if params[:q]
      @locations = Location.where name: /#{params[:q]}/
      halt json @locations.to_a
    end

    @locations = Location.all

    erb :"locations/index"
  end
  
  get "/locations/:location_id/maps" do
    @location = Location.find params[:location_id]
    erb :"maps/index"
  end
  
  # new 'em up
  
  get "/locations/new" do
    @location = Location.new
    erb :"locations/new"
  end

  get "/locations/:location_id/maps/new" do
    @location = Location.find params[:location_id]
    erb :"maps/new"
  end
  
  # show 'em
  
  get "/locations/:location_id" do
    @location = Location.find params[:location_id]
    erb :"locations/show"
  end

  get "/locations/:location_id/maps/:map_id" do
    @location = Location.find params[:location_id]
    @map = @location.maps.find params[:map_id]
   
    @map.pins.each { |pin| pin.location }
    
    if request.accept? "text/html"
      signer = Aws::S3::Presigner.new
      @url = signer.presigned_url :get_object, bucket: "smistore", key: @map.key
      scheme = request.scheme == "http" ? "ws" : "wss"
      @ws_url = "#{scheme}://#{request.host}:#{request.port}"
      erb :"maps/show"
    else
      json location: @location, map: @map
    end
  end
  
  # create 'em
  
  post "/locations" do
    location = Location.create name: params[:name]
    redirect "/locations/#{location.id}"
  end

  post "/locations/:location_id/maps" do
    location = Location.find params[:location_id]
    filename = params[:map][:filename]
    file = params[:map][:tempfile]
    obj = bucket.object "#{filename}"

    # don't overwrite dups

    if obj.upload_file file
      map = location.maps.create key: obj.key
      redirect "/locations/#{location.id}/maps/#{map.id}"
    else
      redirect "/error?upload_error"
    end
  end

  post "/locations/:location_id/maps/:map_id/pins" do
    location = Location.find params[:location_id]
    map = location.maps.find params[:map_id]

    pin = begin
            map.pins.find_by key: params[:key]
          rescue
            map.pins.new key: params[:key], name: params[:name]
          end

    if params[:x] && params[:y]
      pin.update_attributes x: params[:x], y: params[:y]
    elsif params[:comment] && params[:comment_key] && params[:comment_name]
      pin.bits.create name: params[:comment_name], key: params[:comment_key], comment: params[:comment]
    elsif params[:location_id]
      linkable_location = Location.find params[:location_id]
      pin.update_attributes location: linkable_location
    end

    json location: location, map: map, pin: pin
  end
end
