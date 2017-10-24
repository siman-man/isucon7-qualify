class User
  class << self
    def init
      @users = {}
      @name_users = {}
      db.query('SELECT * from user order by id asc').each(&:update)
    end

    def update user
      @users[user['id']] = user
    end

    def find id
      @users[id]
    end

    def find_by_name name
      @name_users[name]
    end

    def update user
      @users[user['id']] = user
      @users[user['name']] = user
    end
  end
end

class Channel
  class << self
    def init
      @id_channels = {}
      @channel_list = []
      db.query('SELECT * from channel order by id asc').each(&:update)
    end

    def list
      @channel_list
    end

    def update channel
      id = channel['id']
      return if @id_channels[id]
      @id_channels[id] = channel
      if last && last['id'] > id
        @channel_list = (@channel_list + [channel]).sort_by { |a| a['id'] }
      else
        @channel_list << channel
      end
    end

    def find id
      @id_channels[id]
    end
  end
end

class ChannelMessageIds
  class << self
    def init
      @message_channel_ids = {}
      @last_id = 0
      @mutex = Mutex.new
      fetch
    end

    def message_ids channel_id
      @message_channel_ids[channel_id] || []
    end

    def message_count_lte channel_id, message_id
      ids = @message_channel_ids[channel_id]
      ids ? ids.bsearch_index{ |i| i > message_id } || ids.size : 0
    end

    def fetch
      statement = db.prepare('SELECT id, channel_id from message WHERE id > ? order by id asc')
      result = statement.execute(@last_id)
      @mutex.synchronize do
        result.each do |message|
          id = message['id'.freeze]
          arr = (@message_channel_ids[message['channel_id'.freeze]] ||= [])
          arr << id if arr.empty? || arr.last < id
          @last_id = id if id > @last_id
        end
      end
      statement.close
    end
  end
end

class ReadCount
  class << self
    def init
      @user_channel_reads = {}
      @last_updated_at = Time.new(0)
      fetch
    end

    def user_channel_reads user_id, channel_id
      channel_reads = @user_channel_reads[user_id]
      channel_reads ? channel_reads[channel_id] || 0 : 0
    end

    def fetch
      statement = db.prepare('SELECT updated_at, user_id, channel_id, message_id from haveread WHERE updated_at > ? order by updated_at asc')
      statement.execute(@last_updated_at - 1).each do |haveread|
        message_id = haveread['message_id'.freeze]
        channel_id = haveread['channel_id'.freeze]
        channel_reads = @user_channel_reads[haveread['user_id'.freeze]] ||= Hash.new
        channel_reads[channel_id] = ChannelMessageIds.message_count_lte(channel_id, message_id)
        @last_updated_at = haveread['updated_at'.freeze]
      end
      statement.close
    end
  end
end
