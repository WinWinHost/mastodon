# frozen_string_literal: true

class TrendingTags
  KEY                  = 'trending_tags'
  HALF_LIFE            = 1.day.to_i
  MAX_ITEMS            = 500
  EXPIRE_HISTORY_AFTER = 7.days.seconds

  class << self
    def record_use!(tag, account, at_time = Time.now.utc)
      return if disallowed_hashtags.include?(tag.name) || account.silenced? || account.bot?

      increment_historical_use!(tag.id, at_time)
      increment_unique_use!(tag.id, account.id, at_time)
      increment_vote!(tag.id, at_time)
    end

    def get(limit)
      tag_ids = redis.zrevrange(KEY, 0, limit).map(&:to_i)
      tags    = Tag.where(id: tag_ids).to_a.map { |tag| [tag.id, tag] }.to_h
      tag_ids.map { |tag_id| tags[tag_id] }.compact
    end

    private

    def increment_vote!(tag_id, at_time)
      expected = redis.pfcount("activity:tags:#{tag_id}:#{(at_time - 1.day).beginning_of_day.to_i}:accounts")
      expected = 1 if expected.zero?
      observed = redis.pfcount("activity:tags:#{tag_id}:#{at_time.beginning_of_day.to_i}:accounts")

      return if expected > observed

      chi_score = ((observed.to_f - expected.to_f) ** 2) / expected.to_f

      redis.zadd(KEY, chi_score, tag_id.to_s)
      redis.zremrangebyscore(KEY, 0, 0)
    end

    def increment_historical_use!(tag_id, at_time)
      key = "activity:tags:#{tag_id}:#{at_time.beginning_of_day.to_i}"
      redis.incrby(key, 1)
      redis.expire(key, EXPIRE_HISTORY_AFTER)
    end

    def increment_unique_use!(tag_id, account_id, at_time)
      key = "activity:tags:#{tag_id}:#{at_time.beginning_of_day.to_i}:accounts"
      redis.pfadd(key, account_id)
      redis.expire(key, EXPIRE_HISTORY_AFTER)
    end

    # The epoch needs to be 2.5 years in the future if the half-life is one day
    # While dynamic, it will always be the same within one year
    def epoch
      @epoch ||= Date.new(Date.current.year + 2.5, 10, 1).to_datetime.to_i
    end

    def disallowed_hashtags
      return @disallowed_hashtags if defined?(@disallowed_hashtags)

      @disallowed_hashtags = Setting.disallowed_hashtags.nil? ? [] : Setting.disallowed_hashtags
      @disallowed_hashtags = @disallowed_hashtags.split(' ') if @disallowed_hashtags.is_a? String
      @disallowed_hashtags = @disallowed_hashtags.map(&:downcase)
    end

    def redis
      Redis.current
    end
  end
end
