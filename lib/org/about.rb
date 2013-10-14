require "time"

module Org
  class About < Sinatra::Base
    helpers Helpers::Common

    configure do
      set :views, Config.root + "/views"
    end

    before do
      log :access_info, pjax: pjax?
      cache_control :public, :must_revalidate, max_age: 3600
    end

    get "/about" do
      @title = "About"
      slim :about, layout: !pjax?
    end

    get "/data/performance-metrics" do
      librato = Excon.new(Config.librato_url)
      responses = librato.requests([
        build_request("requests.latency.median"),
        build_request("requests.latency.perc95"),
        build_request("requests.latency.perc99"),
      ]).map { |r| MultiJson.decode(r.body)["measurements"]["unassigned"] }

      # We want to do as few API calls as possible so allow rack-cache to take
      # care of caching these results for us. The chart's resolution is 60s, so
      # we only need to freshen the data at that rate.
      cache_control :public, :must_revalidate, max_age: 60
      content_type :json

      MultiJson.encode({
        axis: responses[0].map { |i|
          Time.at(i["measure_time"]).strftime("%H:%M")
        },
        data: {
          p50: responses[0].map { |i| i["value"] },
          p95: responses[1].map { |i| i["value"] },
          p99: responses[2].map { |i| i["value"] },
        }
      })
    end

    private

    def build_request(metric)
      {
        expects: 200,
        method: :get,
        path: "/v1/metrics/#{metric}",
        query: {
          count: 10,
          resolution: 60,
        }
      }
    end
  end
end
