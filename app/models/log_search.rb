class LogSearch
  attr_accessor :query, :query_options
  attr_reader :client, :start_time, :end_time, :interval, :region, :country, :state

  def initialize(options = {})
    @client = Elasticsearch::Client.new({
      :hosts => ApiUmbrellaConfig[:elasticsearch][:hosts],
      :logger => Rails.logger
    })

    @start_time = options[:start_time]
    unless(@start_time.kind_of?(Time))
      @start_time = Time.zone.parse(@start_time)
    end

    @end_time = options[:end_time]
    unless(@end_time.kind_of?(Time))
      @end_time = Time.zone.parse(@end_time).end_of_day
    end

    if(@end_time > Time.zone.now)
      @end_time = Time.zone.now
    end

    @interval = options[:interval]
    @region = options[:region]

    @query = {
      :query => {
        :filtered => {
          :query => {
            :match_all => {},
          },
          :filter => {
            :bool => {
              :must => [],
            },
          },
        },
      },
      :sort => [
        { :request_at => :desc },
      ],
      :aggregations => {},
    }

    @query_options = {
      :size => 0,
      :ignore_unavailable => "missing",
      :allow_no_indices => true,
    }
  end

  def result
    raw_result = @client.search(@query_options.merge({
      :index => indexes.join(","),
      :body => @query,
    }))

    @result = LogResult.new(self, raw_result)
  end

  def permission_scope!(scopes)
    filter = {
      :bool => {
        :should => []
      },
    }

    scopes.each do |scope|
      filter[:bool][:should] << scope
    end

    @query[:query][:filtered][:filter][:bool][:must] << filter
  end

  def search_type!(search_type)
    @query_options[:search_type] = search_type
  end

  def search!(query_string)
    if(query_string.present?)
      @query[:query][:filtered][:query] = {
        :query_string => {
          :query => query_string
        },
      }
    end
  end

  def offset!(from)
    @query_options[:from] = from
  end

  def limit!(size)
    @query_options[:size] = size
  end

  def sort!(sort)
    @query[:sort] = sort
  end

  def filter_by_date_range!
    @query[:query][:filtered][:filter][:bool][:must] << {
      :range => {
        :request_at => {
          :from => @start_time.iso8601,
          :to => @end_time.iso8601,
        },
      },
    }
  end

  def filter_by_request_path!(request_path)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :request_path => request_path,
      },
    }
  end

  def filter_by_api_key!(api_key)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :api_key => api_key,
      },
    }
  end

  def filter_by_user!(user_email)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :user => {
          :user_email => user_email,
        },
      },
    }
  end

  def filter_by_user_ids!(user_ids)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :terms => {
        :user_id => user_ids,
      },
    }
  end

  def aggregate_by_interval!
    @query[:aggregations][:hits_over_time] = {
      :date_histogram => {
        :field => "request_at",
        :interval => @interval,
        :time_zone => Time.zone.name,
        :pre_zone_adjust_large_interval => true,
        :min_doc_count => 0,
        :extended_bounds => {
          :min => @start_time.iso8601,
          :max => @end_time.iso8601,
        },
      },
    }
  end

  def aggregate_by_region!
    case(@region)
    when "world"
      aggregate_by_country!
    when "US"
      @country = @region
      aggregate_by_country_regions!(@region)
    when /^(US)-([A-Z]{2})$/
      @country = Regexp.last_match[1]
      @state = Regexp.last_match[2]
      aggregate_by_us_state_cities!(@country, @state)
    else
      @country = @region
      aggregate_by_country_cities!(@region)
    end
  end

  def aggregate_by_region_field!(field)
    @query[:aggregations][:regions] = {
      :terms => {
        :field => field.to_s,
        :size => 500,
      },
    }

    @query[:aggregations][:missing_regions] = {
      :missing => {
        :field => field.to_s,
      },
    }
  end

  def aggregate_by_country!
    aggregate_by_region_field!(:request_ip_country)
  end

  def aggregate_by_country_regions!(country)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }

    aggregate_by_region_field!(:request_ip_region)
  end

  def aggregate_by_us_state_cities!(country, state)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_region => state },
    }

    aggregate_by_region_field!(:request_ip_city)
  end

  def aggregate_by_country_cities!(country)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }

    aggregate_by_region_field!(:request_ip_city)
  end

  def aggregate_by_term!(field, size)
    @query[:aggregations]["top_#{field.to_s.pluralize}"] = {
      :terms => {
        :field => field.to_s,
        :size => size,
        :shard_size => size * 4,
      },
    }

    @query[:aggregations]["value_count_#{field.to_s.pluralize}"] = {
      :value_count => {
        :field => field.to_s,
      },
    }

    @query[:aggregations]["missing_#{field.to_s.pluralize}"] = {
      :missing => {
        :field => field.to_s,
      },
    }
  end

  def aggregate_by_cardinality!(field)
    @query[:aggregations]["unique_#{field.to_s.pluralize}"] = {
      :cardinality => {
        :field => field.to_s,
        :precision_threshold => 100,
      },
    }
  end

  def aggregate_by_users!(size)
    aggregate_by_term!(:user_email, size)
    aggregate_by_cardinality!(:user_email)
  end

  def aggregate_by_request_ip!(size)
    aggregate_by_term!(:request_ip, size)
    aggregate_by_cardinality!(:request_ip)
  end

  def aggregate_by_user_stats!(options = {})
    @query[:aggregations][:user_stats] = {
      :terms => {
        :field => :user_id,
        :size => 0,
      }.merge(options),
      :aggregations => {
        :last_request_at => {
          :max => {
            :field => :request_at,
          },
        },
      },
    }
  end

  def aggregate_by_response_time_average!
    @query[:aggregations][:response_time_average] = {
      :avg => {
        :field => :response_time,
      },
    }
  end

  private

  def indexes
    unless @indexes
      date_range = @start_time.utc.to_date..@end_time.utc.to_date
      @indexes = date_range.map { |date| "api-umbrella-logs-#{Rails.env}-#{date.strftime("%Y-%m")}" }
      @indexes.uniq!
    end

    @indexes
  end
end
