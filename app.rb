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

  # Shared serializer — single source of truth for record structure.
  # All endpoints (today, date, month, year) call this.
  def serialize_row(row)
    date  = row[:date]
    times = {
      subuh:   row[:subuh],
      syuruk:  row[:syuruk],
      zohor:   row[:zohor],
      asar:    row[:asar],
      maghrib: row[:maghrib],
      isyak:   row[:isyak]
    }
    {
      date:          date,
      day:           day_name(date),
      friendly_date: friendly_date(date),
      hijri_date:    row[:hijri_date_text],
      times:         times,
      times_ampm:    times.transform_values { |v| to_ampm(v) }
    }
  end

  def valid_year?(year)
    year.between?(2000, 2100)
  end

  def valid_month?(month)
    month.between?(1, 12)
  end
end

# ---------------------------------------------------------------------------
# Index
# ---------------------------------------------------------------------------

get "/" do
  content_type "text/html"
  <<~HTML
    <h1>PrayertimesSG API</h1>
    <p>Status: OK</p>
    <ul>
      <li><a href="/api/v1/prayer-times/today">/api/v1/prayer-times/today</a></li>
      <li><a href="/api/v1/prayer-times?date=2026-01-01">/api/v1/prayer-times?date=YYYY-MM-DD</a></li>
      <li><a href="/api/v1/prayer-times/month/2026/05">/api/v1/prayer-times/month/:year/:month</a></li>
      <li><a href="/api/v1/prayer-times/year/2026">/api/v1/prayer-times/year/:year</a></li>
    </ul>
    <p>&copy; 2026 ROQOM</p>
  HTML
end

# ---------------------------------------------------------------------------
# Single-date endpoints
# ---------------------------------------------------------------------------

# GET /api/v1/prayer-times?date=YYYY-MM-DD
get "/api/v1/prayer-times" do
  date = params["date"] or error!(400, "Missing ?date=YYYY-MM-DD")
  Date.iso8601(date) rescue error!(400, "Invalid date format")

  row = T.where(date: date).first or error!(404, "No data for #{date}")

  headers "Cache-Control" => "public, max-age=3600, must-revalidate",
          "ETag"          => "\"prayer-times-#{date}\""

  serialize_row(row).to_json
end

# GET /api/v1/prayer-times/today (Singapore timezone +08:00)
get "/api/v1/prayer-times/today" do
  today = Time.now.getlocal("+08:00").to_date.to_s

  row = T.where(date: today).first or error!(404, "No data for #{today}")

  headers "Cache-Control" => "public, max-age=3600, must-revalidate",
          "ETag"          => "\"prayer-times-#{today}\""

  serialize_row(row).to_json
end

# ---------------------------------------------------------------------------
# Bulk endpoints
# ---------------------------------------------------------------------------

# GET /api/v1/prayer-times/month/:year/:month
# Example: /api/v1/prayer-times/month/2026/05
get "/api/v1/prayer-times/month/:year/:month" do
  year  = params[:year].to_i
  month = params[:month].to_i

  error!(400, "Invalid year")  unless valid_year?(year)
  error!(400, "Invalid month") unless valid_month?(month)

  first_day = "%04d-%02d-01" % [year, month]
  last_day  = Date.new(year, month, -1).to_s

  rows = T.where(date: first_day..last_day).order(:date).all
  error!(404, "No data for #{year}-%02d" % month) if rows.empty?

  headers "Cache-Control" => "public, max-age=3600"

  {
    year:  year,
    month: month,
    count: rows.size,
    data:  rows.map { |r| serialize_row(r) }
  }.to_json
end

# GET /api/v1/prayer-times/year/:year
# Example: /api/v1/prayer-times/year/2026
get "/api/v1/prayer-times/year/:year" do
  year = params[:year].to_i

  error!(400, "Invalid year") unless valid_year?(year)

  rows = T.where(Sequel.like(:date, "#{year}-%")).order(:date).all
  error!(404, "No data for #{year}") if rows.empty?

  headers "Cache-Control" => "public, max-age=3600"

  {
    year:  year,
    count: rows.size,
    data:  rows.map { |r| serialize_row(r) }
  }.to_json
end
