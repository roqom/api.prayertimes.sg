require "csv"
require "date"
require "sequel"

DB = Sequel.sqlite("db/dev.sqlite3")
T  = DB[:prayer_times_sg]

def valid_hhmm?(s)
  /\A([01]\d|2[0-3]):[0-5]\d\z/.match?(s)
end

path = ARGV[0] or abort "Usage: ruby scripts/import_csv.rb data/muis_2026.csv"

CSV.foreach(path, headers: true) do |row|
  date = Date.iso8601(row["date"].strip).to_s

  times = %w[subuh syuruk zohor asar maghrib isyak].to_h do |k|
    v = row[k].strip
    abort "Invalid #{k} time: #{v}" unless valid_hhmm?(v)
    [k.to_sym, v]
  end

  payload = {
    date: date,
    hijri_date_text: row["hijri_date_text"]&.strip
  }.merge(times)

  T.insert_conflict(
    target: :date,
    update: payload.reject { |k, _| k == :date }
  ).insert(payload)
end

puts "Import complete."
