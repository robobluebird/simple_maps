require "sinatra"
require "aws-sdk-s3"
require "json"
require "mini_magick"
require "mongoid"
require "sinatra/base"
require "sinatra/json"

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

  field :name, type: String
  field :key, type: String
  field :linked_pin, type: Hash
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

  field :x, type: Float
  field :y, type: Float
  field :key, type: String
  field :name, type: String
  field :linked_location, type: Hash
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
    erb :index
  end
  
  # list 'em
  
  get "/locations" do
    if params[:q]
      @locations = Location.where name: /#{params[:q]}/i
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
    @base_cloudfront_url = ENV["CLOUDFRONT_BASE_URL"]
    erb :"locations/show"
  end

  get "/locations/:location_id/maps/:map_id" do
    @location = Location.find params[:location_id]
    @map = @location.maps.find params[:map_id]

    if request.accept? "text/html"
      @url = "#{ENV["CLOUDFRONT_BASE_URL"]}/large/#{@map.key}"
      scheme = request.scheme == "http" ? "ws" : "wss"
      @ws_url = "#{scheme}://#{request.host}:#{request.port}"
      erb :"maps/show"
    else
      map_json = @map.as_json(methods: [:linked_location])

      # assign "id" method to all embedded collections
      if map_json["pins"]
        map_json["pins"].each do |pin|
          pin["id"] = pin["_id"].to_s

          if pin["bits"]
            pin["bits"].each do |bit|
              bit["id"] = bit["_id"].to_s
            end
          end
        end
      end
      # ^ remove_this ^
      
      json location: @location, map: map_json, linked_pin: @location.linked_pin
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

    small_tempfile = Tempfile.new
    small_file = MiniMagick::Image.open file.path
    small_file.resize "500x500"
    small_file.write small_tempfile.path

    small_obj = bucket.object "small/#{filename}"
    large_obj = bucket.object "large/#{filename}"

    if small_obj.upload_file(small_tempfile) && large_obj.upload_file(file)
      small_tempfile.close
      small_tempfile.unlink
      map = location.maps.create key: filename
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
    elsif params[:linked_location_id]
      linkable_location = Location.find params[:linked_location_id]

      linkable_location.linked_pin = {
        key: pin.key,
        map: {
          id: map.id.to_s,
          location: {
            name: location.name,
            id: location.id.to_s,
          }
        }
      }

      pin.linked_location = {
        id: linkable_location.id.to_s,
        name: linkable_location.name
      }

      linkable_location.save
      pin.save
    end

    json location: location, map: map, pin: pin
  end
end
