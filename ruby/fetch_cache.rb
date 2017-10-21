class User
  class << self
    def init
      @users = {}
      @last_id = 0
      fetch
    end

    def get id
      @users[id]
    end

    def fetch
      statement = db.prepare('SELECT * from user WHERE id > ? order by id asc')
      statement.execute(@last_id).each do |user|
        id = user['id'.freeze]
        @users[id] = user
        @last_id = id
      end
      statement.close
    end
  end
end

class Channel
  class << self
    def init
      @id_channels = {}
      @channel_list = []
      @last_id = 0
      fetch
    end

    def list
      @channel_list
    end

    def find id
      @id_channels[id]
    end

    def fetch
      statement = db.prepare('SELECT * from channel WHERE id > ? order by id asc')
      statement.execute(@last_id).each do |channel|
        id = channel['id'.freeze]
        @id_channels[id] = channel
        @channel_list << channel
        @last_id = id
      end
      statement.close
    end
  end
end

class ChannelMessageIds
  class << self
    def init
      @message_channel_ids = {}
      @last_id = 0
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
      statement.execute(@last_id).each do |message|
        id = message['id'.freeze]
        (@message_channel_ids[message['channel_id'.freeze]] ||= []) << id
        @last_id = id
      end
      statement.close
    end
  end
end

class ReadCount
  class << self
    def init
      @user_channel_reads = {}
      @last_created_at = Time.new(0)
      fetch
    end

    def user_channel_reads user_id, channel_id
      channel_reads = @user_channel_reads[user_id]
      channel_reads ? channel_reads[channel_id]&.first || 0 : 0
    end

    def fetch
      statement = db.prepare('SELECT created_at, user_id, channel_id, message_id from haveread WHERE created_at > ? order by created_at asc')
      statement.execute(@last_created_at - 1).each do |haveread|
        message_id = haveread['message_id'.freeze]
        channel_id = haveread['channel_id'.freeze]
        channel_reads = @user_channel_reads[haveread['user_id'.freeze]] ||= Hash.new
        count, last_read_id = channel_reads[channel_id]
        channel_reads[channel_id] = ChannelMessageIds.message_count_lte(channel_id, message_id), message_id
        @last_created_at = haveread['created_at'.freeze]
      end
      statement.close
    end
  end
end
