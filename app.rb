require "sinatra"
require "json"
require "date"
require "time"
require "sequel"

DB = Sequel.sqlite(ENV.fetch("DB_PATH", "db/dev.sqlite3"))
T  = DB[:prayer_times_sg]

# Shared base CSS used by every HTML page.
SHARED_CSS = <<~CSS
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, -apple-system, sans-serif; color: #111827; line-height: 1.6; }
  a { text-decoration: none; }
  a:hover { text-decoration: underline; }
  h2 { font-size: 0.7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; color: #9ca3af; margin-bottom: 0.75rem; }
  .info-grid { border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden; }
  .info-row { display: flex; justify-content: space-between; align-items: center; padding: 0.75rem 1rem; border-bottom: 1px solid #f3f4f6; font-size: 0.875rem; }
  .info-row:last-child { border-bottom: none; }
  .info-label { color: #6b7280; }
  .info-value { font-weight: 500; text-align: right; }
  .site-footer { text-align: center; padding: 2rem 1.5rem 1.5rem; }
  .site-footer small { font-size: 0.8rem; color: #d1d5db; display: block; margin-top: 0.75rem; }
CSS

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

  # ---------------------------------------------------------------------------
  # Shared HTML layout — wraps every HTML page.
  # Provides: DOCTYPE shell, shared CSS, shared footer.
  # ---------------------------------------------------------------------------

  def html_layout(title:, extra_css: "")
    content = yield
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{title}</title>
        <style>
          #{SHARED_CSS}
          #{extra_css}
        </style>
      </head>
      <body>
        #{content}
      <footer class="site-footer">
          <script type="text/javascript" src="https://cdnjs.buymeacoffee.com/1.0.0/button.prod.min.js" data-name="bmc-button" data-slug="tasnimr" data-color="#FFDD00" data-emoji="☕" data-font="Cookie" data-text="Buy me a coffee" data-outline-color="#000000" data-font-color="#000000" data-coffee-color="#ffffff"></script>
          <small>&copy; 2026 ROQOM</small>
        </footer>
      </body>
      </html>
    HTML
  end

  # ---------------------------------------------------------------------------
  # Health check logic — single function used by both /health and /health.json
  # ---------------------------------------------------------------------------

  def run_health_checks
    t_start = Time.now
    now     = Time.now.getlocal("+08:00")
    today   = now.to_date
    tomorrow         = today + 1
    seven_days_later = today + 6  # today + 6 more = 7 days inclusive

    # --- defaults (used if DB is unreachable) --------------------------------
    db_ok          = false
    today_data     = false
    today_valid    = false
    tomorrow_data  = false
    next_7_days_ok = false
    latest_future  = false
    coverage_start = nil
    coverage_end   = nil
    total_records  = 0

    begin
      total_records  = T.count
      coverage_start = T.order(:date).first&.dig(:date)
      coverage_end   = T.order(Sequel.desc(:date)).first&.dig(:date)
      db_ok          = true

      today_row  = T.where(date: today.to_s).first
      today_data = !today_row.nil?

      if today_data
        ordered = %i[subuh syuruk zohor asar maghrib isyak].map { |k| today_row[k] }
        today_valid = ordered.each_cons(2).all? { |a, b| a < b }
      end

      tomorrow_data  = T.where(date: tomorrow.to_s).count.positive?
      next_7_days_ok = T.where(date: today.to_s..seven_days_later.to_s).count >= 7
      latest_future  = coverage_end ? Date.iso8601(coverage_end) > today : false
    rescue StandardError
      # DB unreachable — all flags remain false
    end

    response_time_ms = ((Time.now - t_start) * 1000).round

    # --- overall status ------------------------------------------------------
    if !db_ok || !today_data || !today_valid
      status  = "service_issue"
      message = "Prayer time data is temporarily unavailable."
    elsif !tomorrow_data || !next_7_days_ok || !latest_future
      status  = "attention_required"
      message = "Prayer times are available, but some data coverage checks need attention."
    else
      status  = "operational"
      message = "Prayer times are available and based on the official MUIS prayer timetable."
    end

    {
      status:           status,
      message:          message,
      data_source:      "Official MUIS Prayer Timetable",
      coverage: {
        start_date:    coverage_start,
        end_date:      coverage_end,
        total_records: total_records
      },
      checks: {
        database:              db_ok,
        today_data:            today_data,
        today_data_valid:      today_valid,
        tomorrow_data:         tomorrow_data,
        next_7_days_available: next_7_days_ok,
        latest_date_in_future: latest_future
      },
      response_time_ms: response_time_ms,
      checked_at:       now.iso8601
    }
  end
end

# ---------------------------------------------------------------------------
# Index
# ---------------------------------------------------------------------------

get "/" do
  content_type "text/html"

  coverage_start = T.order(:date).first&.dig(:date)
  coverage_end   = T.order(Sequel.desc(:date)).first&.dig(:date)
  total_records  = T.count

  coverage_str = if coverage_start && coverage_end
    "#{friendly_date(coverage_start)} &ndash; #{friendly_date(coverage_end)}"
  else
    "No data"
  end

  html_layout(title: "PrayerTimesSG API", extra_css: <<~CSS) do
    body { background: #fff; }
    .container { max-width: 720px; margin: 0 auto; padding: 3rem 1.5rem; }
    header { margin-bottom: 2.5rem; }
    header h1 { font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 0.4rem; }
    .subtitle { font-size: 0.95rem; color: #6b7280; margin-bottom: 1rem; }
    .badge-operational { display: inline-block; padding: 0.2em 0.75em; border-radius: 999px; font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; background: #dcfce7; color: #15803d; }
    section { margin-bottom: 2.5rem; }
    .endpoint-list { border: 1px solid #e5e7eb; border-radius: 10px; overflow: hidden; }
    .endpoint { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; padding: 0.8rem 1rem; border-bottom: 1px solid #f3f4f6; }
    .endpoint:last-child { border-bottom: none; }
    .method { font-size: 0.7rem; font-weight: 700; color: #2563eb; background: #eff6ff; padding: 0.15em 0.5em; border-radius: 4px; flex-shrink: 0; }
    .endpoint-path { font-family: ui-monospace, monospace; font-size: 0.85rem; font-weight: 500; color: #111827; flex: 1; }
    .endpoint-desc { font-size: 0.8rem; color: #6b7280; text-align: right; flex-shrink: 0; }
    @media (max-width: 540px) {
      .endpoint { flex-wrap: wrap; gap: 0.3rem; }
      .endpoint-desc { text-align: left; width: 100%; padding-left: calc(0.7rem + 1.5rem); }
    }
    .example { background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 10px; padding: 1rem 1.25rem; overflow-x: auto; }
    .example pre { font-family: ui-monospace, monospace; font-size: 0.8rem; line-height: 1.7; color: #374151; white-space: pre; }
  CSS
    <<~BODY
      <div class="container">

        <header>
          <h1>PrayerTimesSG API</h1>
          <p class="subtitle">Reliable Singapore prayer times API based on the official MUIS prayer timetable.</p>
          <span class="badge-operational">Operational</span>
        </header>

        <section>
          <h2>Endpoints</h2>
          <div class="endpoint-list">
            <div class="endpoint">
              <span class="method">GET</span>
              <span class="endpoint-path"><a href="/api/v1/prayer-times/today">/api/v1/prayer-times/today</a></span>
              <span class="endpoint-desc">Get today&#39;s prayer times.</span>
            </div>
            <div class="endpoint">
              <span class="method">GET</span>
              <span class="endpoint-path"><a href="/api/v1/prayer-times?date=2026-01-01">/api/v1/prayer-times?date=YYYY-MM-DD</a></span>
              <span class="endpoint-desc">Get prayer times for a specific date.</span>
            </div>
            <div class="endpoint">
              <span class="method">GET</span>
              <span class="endpoint-path"><a href="/api/v1/prayer-times/month/2026/05">/api/v1/prayer-times/month/:year/:month</a></span>
              <span class="endpoint-desc">Get prayer times for a specific month.</span>
            </div>
            <div class="endpoint">
              <span class="method">GET</span>
              <span class="endpoint-path"><a href="/api/v1/prayer-times/year/2026">/api/v1/prayer-times/year/:year</a></span>
              <span class="endpoint-desc">Get prayer times for a specific year.</span>
            </div>
          </div>
        </section>

        <section>
          <h2>System</h2>
          <div class="endpoint-list">
            <div class="endpoint">
              <span class="method">GET</span>
              <span class="endpoint-path"><a href="/health">/health</a></span>
              <span class="endpoint-desc">Human-readable health page.</span>
            </div>
            <div class="endpoint">
              <span class="method">GET</span>
              <span class="endpoint-path"><a href="/health.json">/health.json</a></span>
              <span class="endpoint-desc">JSON health endpoint for monitoring.</span>
            </div>
          </div>
        </section>

        <section>
          <h2>Data Source</h2>
          <div class="info-grid">
            <div class="info-row">
              <span class="info-label">Source</span>
              <span class="info-value">Official MUIS Prayer Timetable &mdash; <a href="https://data.gov.sg">data.gov.sg</a></span>
            </div>
            <div class="info-row">
              <span class="info-label">Coverage</span>
              <span class="info-value">#{coverage_str}</span>
            </div>
            <div class="info-row">
              <span class="info-label">Records Loaded</span>
              <span class="info-value">#{total_records} days</span>
            </div>
          </div>
        </section>

        <section>
          <h2>Example Response</h2>
          <p style="font-size:0.8rem;color:#6b7280;margin-bottom:0.6rem;">GET /api/v1/prayer-times/today</p>
          <div class="example">
            <pre>{
  "date": "2026-05-29",
  "day": "Friday",
  "friendly_date": "29 May 2026",
  "hijri_date": "12 Zulhijjah 1447",
  "times": {
    "subuh":   "05:37",
    "syuruk":  "07:01",
    "zohor":   "13:04",
    "asar":    "16:24",
    "maghrib": "19:07",
    "isyak":   "20:19"
  },
  "times_ampm": {
    "subuh":   "5:37 AM",
    "syuruk":  "7:01 AM",
    "zohor":   "1:04 PM",
    "asar":    "4:24 PM",
    "maghrib": "7:07 PM",
    "isyak":   "8:19 PM"
  }
}</pre>
          </div>
        </section>

      </div>
    BODY
  end
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

# ---------------------------------------------------------------------------
# Health endpoints
# ---------------------------------------------------------------------------

# GET /health.json — for monitoring systems (must come before /health to avoid
# Sinatra treating ".json" as a format extension on the :id param)
get "/health.json" do
  h = run_health_checks
  status (h[:status] == "service_issue" ? 503 : 200)
  h.to_json
end

# GET /health — human-friendly HTML page
get "/health" do
  content_type "text/html"
  h = run_health_checks

  badge_class = {
    "operational"        => "badge--green",
    "attention_required" => "badge--yellow",
    "service_issue"      => "badge--red"
  }.fetch(h[:status], "badge--red")

  status_class = {
    "operational"        => "status--green",
    "attention_required" => "status--yellow",
    "service_issue"      => "status--red"
  }.fetch(h[:status], "status--red")

  label = {
    "operational"        => "Operational",
    "attention_required" => "Attention Required",
    "service_issue"      => "Service Issue"
  }.fetch(h[:status], "Unknown")

  cov = h[:coverage]
  chk = h[:checks]

  coverage_str = if cov[:start_date] && cov[:end_date]
    "#{friendly_date(cov[:start_date])} &ndash; #{friendly_date(cov[:end_date])}"
  else
    "No data"
  end

  pass_html = '<span class="pass">&#10003; Pass</span>'
  fail_html = '<span class="fail">&#10007; Fail</span>'

  html_layout(title: "PrayerTimesSG API \u2014 Health", extra_css: <<~CSS) do
    body { background: #f9fafb; }
    a { color: #4b5563; }
    .page-header { padding: 1.25rem 1.5rem; border-bottom: 1px solid #e5e7eb; background: #fff; display: flex; align-items: center; justify-content: space-between; }
    .page-header h1 { font-size: 1rem; font-weight: 600; }
    .page-header a { font-size: 0.85rem; color: #9ca3af; }
    main { max-width: 640px; margin: 0 auto; padding: 2rem 1.5rem; }
    section { margin-bottom: 2rem; }
    .status-card { padding: 1.25rem 1.5rem; border-radius: 10px; margin-bottom: 2rem; }
    .status--green  { background: #f0fdf4; border: 1px solid #bbf7d0; }
    .status--yellow { background: #fffbeb; border: 1px solid #fde68a; }
    .status--red    { background: #fef2f2; border: 1px solid #fecaca; }
    .badge { display: inline-block; padding: 0.2em 0.75em; border-radius: 999px; font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.5rem; }
    .badge--green  { background: #dcfce7; color: #15803d; }
    .badge--yellow { background: #fef9c3; color: #a16207; }
    .badge--red    { background: #fee2e2; color: #b91c1c; }
    .status-message { font-size: 0.925rem; color: #374151; }
    .info-grid { background: #fff; }
    .pass { color: #16a34a; font-weight: 600; }
    .fail { color: #dc2626; font-weight: 600; }
  CSS
    <<~BODY
      <header class="page-header">
        <h1>PrayerTimesSG API</h1>
        <a href="/">&#8592; Back</a>
      </header>

      <main>

        <div class="status-card #{status_class}">
          <span class="badge #{badge_class}">#{label}</span>
          <p class="status-message">#{h[:message]}</p>
        </div>

        <section>
          <h2>Data Source</h2>
          <div class="info-grid">
            <div class="info-row">
              <span class="info-label">Source</span>
              <span class="info-value">Official MUIS Prayer Timetable</span>
            </div>
            <div class="info-row">
              <span class="info-label">Coverage</span>
              <span class="info-value">#{coverage_str}</span>
            </div>
            <div class="info-row">
              <span class="info-label">Records Loaded</span>
              <span class="info-value">#{cov[:total_records]} days</span>
            </div>
            <div class="info-row">
              <span class="info-label">Latest Available Date</span>
              <span class="info-value">#{cov[:end_date] ? friendly_date(cov[:end_date]) : "No data"}</span>
            </div>
          </div>
        </section>

        <section>
          <h2>Checks</h2>
          <div class="info-grid">
            <div class="info-row">
              <span class="info-label">Database</span>
              #{chk[:database] ? pass_html : fail_html}
            </div>
            <div class="info-row">
              <span class="info-label">Today&#39;s Prayer Times</span>
              #{chk[:today_data] ? pass_html : fail_html}
            </div>
            <div class="info-row">
              <span class="info-label">Prayer Time Validation</span>
              #{chk[:today_data_valid] ? pass_html : fail_html}
            </div>
            <div class="info-row">
              <span class="info-label">Tomorrow&#39;s Prayer Times</span>
              #{chk[:tomorrow_data] ? pass_html : fail_html}
            </div>
            <div class="info-row">
              <span class="info-label">Next 7 Days Available</span>
              #{chk[:next_7_days_available] ? pass_html : fail_html}
            </div>
            <div class="info-row">
              <span class="info-label">Latest Available Date in Future</span>
              #{chk[:latest_date_in_future] ? pass_html : fail_html}
            </div>
            <div class="info-row">
              <span class="info-label">Response Time</span>
              <span class="info-value">#{h[:response_time_ms]} ms</span>
            </div>
            <div class="info-row">
              <span class="info-label">Checked At</span>
              <span class="info-value">#{h[:checked_at]}</span>
            </div>
          </div>
        </section>

      </main>
    BODY
  end
end
