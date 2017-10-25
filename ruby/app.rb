# frozen_string_literal: true

require 'digest/sha1'
require 'mysql2'
require 'mysql2-cs-bind'
require 'sinatra/base'
require_relative './db'
require_relative './sync'
require_relative './fetch_cache'
require 'httpclient'
require 'rack-mini-profiler'
require 'rack-lineprof'

$fetch_cond = ConditionVariable.new
$fetch_mutex = Mutex.new
def wait_for_new_fetch(timeout=1)
  $fetch_mutex.synchronize do
    $fetch_cond.wait($fetch_mutex, timeout)
  end
end

def notify_fetch
  $fetch_cond.broadcast
end

def file_initialize
  first_images = db.xquery('select distinct name from image where id <= 1001', as: :array).to_a.flatten.map{|a|[a,true]}.to_h
  Dir.glob(File.expand_path('../public/icons/*.*', __dir__)).each do |path|
    FileUtils.remove_file(path) unless first_images.include? File.basename(path)
  end
end

def onmem_initialize
  User.init
  Channel.init
  ChannelMessageIds.init
  ReadCount.init
end

Events = {}
WorkerCast.start ServerList, SelfServer do |data, respond|
  name, *args = data
  Events[name]&.call(*args, respond)
end

Events['image'] = lambda do |server, filename, respond|
  path = File.expand_path("../public/icons/#{filename}", __dir__)
  begin
    unless File.exist? path
      url = "http://#{ServerList[server.to_sym].split(':').first}/icons/#{filename}"
      File.write path, HTTPClient.get(url).body
    end
    'ok'
  rescue StandardError
    'err'
  end
end

class Task
  def initialize interval: 0, &block
    @mutex = Mutex.new
    @cond = ConditionVariable.new
    @callbacks = []
    @block = block
    @interval = interval
    Thread.new { run }
  end

  def request &callback
    @mutex.synchronize do
      @callbacks << callback
      @cond.signal if @callbacks.size == 1
    end
  end

  def run
    loop do
      callbacks = nil
      @mutex.synchronize do
        @cond.wait @mutex if @callbacks.empty?
        callbacks = @callbacks
        @callbacks = []
      end
      status = @block.call
      callbacks.each { |callback| callback.call status }
      sleep @interval if @interval.nonzero?
    end
  end
end

loop do
  begin
    onmem_initialize
    break
  rescue StandardError => e
    p e
    sleep 5
  end
end

channelmessage_task = Task.new do
  ChannelMessageIds.fetch
  notify_fetch
  :ok
end

readcount_task = Task.new do
  ReadCount.fetch
  :ok
end

Events['message'] = lambda do |respond|
  channelmessage_task.request(&respond)
  :async
end

Events['haveread'] = lambda do |respond|
  readcount_task.request(&respond)
  :async
end

Events['initialize'] = lambda do |respond|
  file_initialize
  onmem_initialize
  'ok'
end

Events['user'] = lambda do |user, respond|
  User.update user
  $message_json_cache = []
  'ok'
end

Events['channel'] = lambda do |channel, respond|
  Channel.update channel
  'ok'
end

class App < Sinatra::Base
  configure do
    set :session_secret, 'tonymoris'
    set :public_folder, File.expand_path('../../public', __FILE__)
    set :avatar_max_size, 1 * 1024 * 1024

    use Rack::Lineprof if ENV['DEBUG']
    use Rack::MiniProfiler if ENV['DEBUG']

    enable :sessions
  end

  configure :production do
    set :show_exceptions, true
  end

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  helpers do
    def user
      return @_user unless @_user.nil?

      user_id = session[:user_id]
      return nil if user_id.nil?

      @_user = User.find(user_id)
      if @_user.nil?
        params[:user_id] = nil
        return nil
      end

      @_user
    end
  end

  get '/initialize' do
    db.xquery("DELETE FROM user WHERE id > 1000")
    db.xquery("DELETE FROM image WHERE id > 1001")
    db.xquery("DELETE FROM channel WHERE id > 10")
    db.xquery("DELETE FROM message WHERE id > 10000")
    db.xquery("DELETE FROM haveread")
    WorkerCast.broadcast ['initialize']
    204
  end

  get '/' do
    if session.has_key?(:user_id)
      return redirect '/channel/1', 303
    end
    erb :index
  end

  get '/channel/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i
    @channels, @description = get_channel_list_info(@channel_id)
    erb :channel
  end

  get '/register' do
    erb :register
  end

  post '/register' do
    name = params[:name]
    pw = params[:password]
    if name.nil? || name.empty? || pw.nil? || pw.empty?
      return 400
    end
    begin
      user_id = register(name, pw)
    rescue Mysql2::Error => e
      return 409 if e.error_number == 1062
      raise e
    end
    session[:user_id] = user_id
    redirect '/', 303
  end

  get '/login' do
    erb :login
  end

  post '/login' do
    row = User.find_by_name params[:name]
    if row.nil? || row['password'] != Digest::SHA1.hexdigest(row['salt'] + params[:password])
      return 403
    end
    session[:user_id] = row['id']
    redirect '/', 303
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/', 303
  end

  post '/message' do
    user_id = session[:user_id]
    message = params[:message]
    channel_id = params[:channel_id]
    if user_id.nil? || message.nil? || channel_id.nil? || user.nil?
      return 403
    end
    db_add_message(channel_id.to_i, user_id, message)
    204
  end

  def message_json_cached id, serialized
    arr = $message_json_cache ||= []
    data = arr[id%10000]
    return if !data || data[0] != id
    if serialized
      return data[2] ||= data[1].to_json
    else
      return data[1]
    end
  end

  def message_jsons ids, serialized: true
    id_jsons = ids.map { |id| [id, message_json_cached(id, serialized)] }
    missings = id_jsons.map { |id, json| id unless json }.compact
    founds = missings.zip(message_jsons_cache missings, serialized).to_h
    id_jsons.map { |id, json| json || founds[id] }
  end

  def message_jsons_cache ids, serialized
    return [] if ids.empty?
    arr = ($message_json_cache ||= [])
    db.query("SELECT * FROM message WHERE id in (#{ids.join(', ')}) order by id asc").map do |message|
      user = User.find(message['user_id'])
      id = message['id']
      json = {
        'id' => id,
        'user' => {
          'name' => user['name'],
          'display_name' => user['display_name'],
          'avatar_icon' => user['avatar_icon']
        },
        'date' => message['created_at'].strftime("%Y/%m/%d %H:%M:%S"),
        'content' => message['content']
      }
      a,b,c = arr[id%10000] = [id, json, (serialized ? json.to_json : nil)]
      serialized ? c : b
    end
  end

  get '/message' do
    user_id = session[:user_id]
    return 403 if user_id.nil?

    channel_id = params[:channel_id].to_i
    last_message_id = params[:last_message_id].to_i

    message_ids = ChannelMessageIds.message_ids(channel_id)
    ids = []
    message_ids.reverse_each do |id|
      break if id <= last_message_id || ids.size == 100
      ids.unshift id
    end

    max_message_id = ids.max || 0
    sql = <<~SQL
      INSERT INTO haveread (user_id, channel_id, message_id, updated_at, created_at)
      VALUES (?, ?, ?, NOW(), NOW())
      ON DUPLICATE KEY UPDATE message_id = ?, updated_at = NOW()
    SQL
    db.xquery(sql, user_id, channel_id, max_message_id, max_message_id)
    WorkerCast.broadcast(['haveread'])
    content_type :json
    "[#{message_jsons(ids).join(',')}]"
  end

  get '/fetch' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    wait_for_new_fetch 5
    sleep 0.2

    res = Channel.list.map do |channel|
      channel_id = channel['id']
      {
        channel_id: channel_id,
        unread: ChannelMessageIds.message_ids(channel_id).size - ReadCount.user_channel_reads(user_id, channel_id)
      }
    end

    content_type :json
    res.to_json
  end

  get '/history/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i

    @page = params[:page]
    if @page.nil?
      @page = '1'
    end
    if @page !~ /\A\d+\Z/ || @page == '0'
      return 400
    end
    @page = @page.to_i

    n = 20
    message_ids = ChannelMessageIds.message_ids(@channel_id)
    cnt = message_ids.size
    @max_page = cnt == 0 ? 1 : cnt.fdiv(n).ceil
    return 400 if @page > @max_page

    ids = []
    offset = (@page - 1) * n
    n.times do |i|
      id = message_ids[-1-offset-i]
      break unless id
      ids.unshift id
    end
    @messages = message_jsons(ids, serialized: false)

    @channels, @description = get_channel_list_info(@channel_id)
    erb :history
  end

  get '/profile/:user_name' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    @user = User.find_by_name params[:user_name]

    if @user.nil?
      return 404
    end

    @self_profile = user['id'] == @user['id']
    erb :profile
  end

  get '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    erb :add_channel
  end

  post '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    name = params[:name]
    description = params[:description]
    if name.nil? || description.nil?
      return 400
    end
    sql = 'INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())'
    db.xquery(sql, name, description)
    channel_id = db.last_id
    channel = db.xquery('SELECT * from channel where id = ?', channel_id).first
    WorkerCast.broadcast(['channel', channel])
    redirect "/channel/#{channel_id}", 303
  end

  post '/profile' do
    if user.nil?
      return redirect '/login', 303
    end

    if user.nil?
      return 403
    end

    display_name = params[:display_name]
    avatar_name = nil
    avatar_data = nil

    file = params[:avatar_icon]
    unless file.nil?
      filename = file[:filename]
      if !filename.nil? && !filename.empty?
        ext = filename.include?('.') ? File.extname(filename) : ''
        unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
          return 400
        end

        if settings.avatar_max_size < file[:tempfile].size
          return 400
        end

        data = file[:tempfile].read
        digest = Digest::SHA1.hexdigest(data)

        avatar_name = digest + ext
        avatar_data = data
      end
    end

    if !avatar_name.nil? && !avatar_data.nil?
      path = File.expand_path("../public/icons/#{avatar_name}", __dir__)
      unless File.exist? path
        File.write path, avatar_data
      end
      puts WorkerCast.broadcast ['image', WorkerCast.server_name, avatar_name], include_self: false
      db.xquery('UPDATE user SET avatar_icon = ? WHERE id = ?', avatar_name, user['id'])
      user['avatar_icon'] = avatar_name
    end

    if !display_name.nil? || !display_name.empty?
      db.xquery('UPDATE user SET display_name = ? WHERE id = ?', display_name, user['id'])
      user['display_name'] = display_name
    end

    WorkerCast.broadcast ['user', user]

    redirect '/', 303
  end

  private

  def db_add_message(channel_id, user_id, content)
    messages = db.xquery('INSERT INTO message (channel_id, user_id, content, created_at) VALUES (?, ?, ?, NOW())', channel_id, user_id, content)
    WorkerCast.broadcast ['message']
  end

  def random_string(n)
    Array.new(20).map { (('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a).sample }.join
  end

  def register(user, password)
    salt = random_string(20)
    pass_digest = Digest::SHA1.hexdigest(salt + password)
    sql = 'INSERT INTO user (name, salt, password, display_name, avatar_icon, created_at) VALUES (?, ?, ?, ?, ?, NOW())'
    db.xquery(sql, user, salt, pass_digest, user, 'default.png')
    user_id = db.last_id
    user = db.xquery('SELECT * from user where id = ?', user_id).first
    WorkerCast.broadcast ['user', user]
    user_id
  end

  def get_channel_list_info(focus_channel_id = nil)
    channels = Channel.list
    channel = Channel.find focus_channel_id
    description = channel['description'] if channel
    [channels, description]
  end
end
