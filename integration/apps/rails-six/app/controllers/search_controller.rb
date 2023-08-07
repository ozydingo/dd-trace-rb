require 'opensearch'

class SearchController < ApplicationController
  def index
    os_client = OpenSearch::Client.new(
      host: 'http://opensearch:9200',
      user: 'admin',
      password: 'admin',
      transport_options: { ssl: { verify: false } }
    )

    render json: os_client.cluster.health
  end
end
