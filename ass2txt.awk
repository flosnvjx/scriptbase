#!/usr/bin/gawk -f

BEGIN {
    count = 0
    # Ensure we use default string comparison (ascending) when iterating by index
    PROCINFO["sorted_in"] = "@ind_str_asc"
}

# Process all standard event types in the [Events] section
/^(Dialogue|Comment|Picture|Sound|Movie|Command):/ {
    # Extract start timestamp and style name
    # Example line: Dialogue: 0,0:00:01.23,0:00:02.00,Default,,0,0,0,,Hello
    if (match($0, /^[A-Za-z]+:\s*[^,]*,\s*([0-9:.]+)[^,]*,([^,]*)/, arr)) {
        start_str = arr[1]   # "0:00:01.23"
        style     = arr[2]   # e.g. "Default"

        # Convert timestamp "h:mm:ss.cs" to a zero-padded centisecond value
        split(start_str, t, ":")
        split(t[3], sc, ".")
        total_cs = t[1] * 360000 + t[2] * 6000 + sc[1] * 100 + sc[2]
        time_key = sprintf("%09d", total_cs)   # fixed width, e.g. "000000123"

        # Extract the Text field (after the 9th comma)
        rest = substr($0, index($0, ":") + 1)
        sub(/^[[:space:]]+/, "", rest)
        sub(/^([^,]*,){9}/, "", rest)          # keep only the text

        # Remove ASS style override tags (e.g., {\i1})
        gsub(/\{[^}]*\}/, "", rest)

        # Build a unique sort key: timestamp (primary) + style (secondary) + counter (uniqueness)
        idx = ++count
        sort_key = time_key ":" style ":" sprintf("%06d", idx)

        # Store the cleaned text under that key
        texts[sort_key] = rest
    }
}

END {
    # Iterate in index-sorted order (thanks to PROCINFO["sorted_in"])
    for (key in texts) {
        print texts[key]
    }
}
