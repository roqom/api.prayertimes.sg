require "sinatra"
require "json"
require "date"
require "time"
require "sequel"

DB = Sequel.sqlite(ENV.fetch("DB_PATH", "db/dev.sqlite3"))
T  = DB[:prayer_times_sg]

before do
  content_type :json
end

helpers do
  def error!(status, msg)
    halt status, { error: msg }.to_json
  end

  def friendly_date(date)
    Date.iso8601(date).strftime("%-d %B %Y")
  end

  def day_name(date)
    Date.iso8601(date).strftime("%A")
  end

  def to_ampm(hhmm)
    Time.strptime(hhmm, "%H:%M").strftime("%-I:%M %p")
  end
end

get "/" do
  content_type "text/html"
  <<~HTML
    <h1>PrayertimesSG API</h1>
    <p>Status: OK</p>
    <ul>
      <li><a href="/api/v1/prayer-times/today">/api/v1/prayer-times/today</a></li>
      <li><a href="/api/v1/prayer-times?date=2026-01-01">/api/v1/prayer-times?date=YYYY-MM-DD</a></li>
    </ul>
    <p>by ROQOM</p> 
  HTML
end


# GET /api/v1/prayer-times?date=YYYY-MM-DD
get "/api/v1/prayer-times" do
  date = params["date"] or error!(400, "Missing ?date=YYYY-MM-DD")
  Date.iso8601(date) rescue error!(400, "Invalid date format")

  row = T.where(date: date).first or error!(404, "No data for #{date}")

  times = {
    subuh: row[:subuh],
    syuruk: row[:syuruk],
    zohor: row[:zohor],
    asar: row[:asar],
    maghrib: row[:maghrib],
    isyak: row[:isyak]
  }

  headers "Cache-Control" => "public, max-age=3600"

  {
    date: date,
    day: day_name(date),
    friendly_date: friendly_date(date),
    hijri_date: row[:hijri_date_text],
    times: times,
    times_ampm: times.transform_values { |v| to_ampm(v) }
  }.to_json
end

# GET /api/v1/prayer-times/today (Singapore)
get "/api/v1/prayer-times/today" do
  today = Time.now.getlocal("+08:00").to_date.to_s
  redirect to("/api/v1/prayer-times?date=#{today}")
end
