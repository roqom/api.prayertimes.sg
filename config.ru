require "./app"
require "rack/cors"

use Rack::Cors do
  allow do
    origins '*' # Allow all origins, or specify domains like 'localhost:3000', 'example.com'
    resource '*', headers: :any, methods: [:get, :post, :put, :delete, :options]
  end
end

run Sinatra::Application