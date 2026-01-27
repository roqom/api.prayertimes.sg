require 'sequel'

DB = Sequel.sqlite("db/dev.sqlite3")

DB.create_table? :prayer_times_sg do
    String :date, primary_key: true

    String :hijri_date_text

    String :subuh,    null: false
    String :syuruk,   null: false
    String :zohor,    null: false
    String :asar,     null: false
    String :maghrib,  null: false
    String :isyak,    null: false
end

puts "OK: prayer_times_sg table created."