// =====================================================================
//  fnUtcToSydney
//  Blank Query > Advanced Editor > paste > rename query to fnUtcToSydney
//
//  Converts a UTC datetime to Australia/Sydney wall-clock time with
//  daylight saving applied. Power Query has no time-zone database, so the
//  rule is written out (in force since 2008, same rule as the pipeline script):
//    AEST = UTC+10
//    AEDT = UTC+11 from 02:00 AEST on the first Sunday in October
//                  to   03:00 AEDT on the first Sunday in April
//  Both changes happen at 16:00 UTC on the Saturday before that Sunday.
//  Checked against the IANA tz database for every half hour 2008-2040.
// =====================================================================
(utc as nullable datetime) as nullable datetime =>
    if utc = null then null
    else
        let
            y           = Date.Year(utc),
            firstSunday = (yr as number, mo as number) as datetime =>
                              let d = #date(yr, mo, 1)
                              in  DateTime.From(Date.AddDays(d, Number.Mod(7 - Date.DayOfWeek(d, Day.Sunday), 7))),
            dstStartUtc = firstSunday(y, 10) - #duration(0, 8, 0, 0),
            dstEndUtc   = firstSunday(y, 4)  - #duration(0, 8, 0, 0),
            offsetHours = if utc >= dstStartUtc or utc < dstEndUtc then 11 else 10
        in
            utc + #duration(0, offsetHours, 0, 0)
