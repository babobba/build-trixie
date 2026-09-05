# Print the parts of a shell script that are in command position, one
# candidate segment per line.  A character-level scan tracks double and
# single quotes across lines, backslash escapes, comments, heredoc bodies
# and command substitution nested inside strings; quoted data is dropped,
# nested "$(...)" and backtick commands are emitted as their own segments.
function push(s) { sp++; st[sp] = s }
function pop()    { if (sp > 0) sp-- }
BEGIN { sp = 0; st[0] = "N"; hd = ""; cont = 0 }
{
	line = $0; sub(/\r$/, "", line)
	if (hd != "") { if (line ~ ("^[[:space:]]*" hd "[[:space:]]*$")) hd = ""; next }
	# after a line ending in a backslash the next line continues the same
	# command: its first word is an argument, not a command
	# a line that begins inside a string (a multi-line gtkdialog layout, a
	# yad --text) is the middle of an argument: whatever follows the string's
	# end on that line is not a command either
	wascont = cont; cont = 0; out = (wascont || st[sp] != "N") ? "_ " : ""
	if (line ~ /(^|[^\\])(\\\\)*\\$/) cont = 1
	# the pattern half of a case arm is not a command - but only at the top
	# level: inside an open $( ... ) a line ending in ")" closes it
	if (sp == 0 && !wascont && st[sp] == "N" && line ~ /^[^()]*\)/) sub(/^[^()]*\)/, "", line)
	n = length(line); prev = " "
	for (i = 1; i <= n; i++) {
		c = substr(line, i, 1); c2 = substr(line, i, 2); s = st[sp]
		if (s == "S") { if (c == "'") pop(); continue }
		if (c == "\\" && s != "S") { i++; prev = "x"; continue }
		if (s == "D") {
			if (c == "\"") pop()
			else if (c2 == "$(") { push("N"); out = out "\n"; i++ }
			else if (c == "`") { push("B"); out = out "\n" }
			continue
		}
		if (s == "B" && c == "`") { pop(); out = out "\n"; prev = " "; continue }
		# N or B: real code
		if (c == "#" && prev ~ /[[:space:]|&;(]/) break
		if (c == "\"") { push("D"); out = out " "; prev = " "; continue }
		if (c == "'") { push("S"); out = out " "; prev = " "; continue }
		if (c2 == "$(") { push("N"); out = out "\n"; i++; prev = " "; continue }
		if (c == "`") { push("B"); out = out "\n"; prev = " "; continue }
		if (c == ")" && sp > 0 && st[sp] == "N") { pop(); out = out "\n"; prev = " "; continue }
		if (c2 == "<<" && st[sp] != "D") {
			rest = substr(line, i + 2); sub(/^-?[[:space:]]*['"]?/, "", rest)
			if (match(rest, /^[A-Za-z_][A-Za-z_0-9]*/)) hd = substr(rest, RSTART, RLENGTH)
		}
		out = out c; prev = c
	}
	# a string left open at end of line continues on the next; the code
	# before it is still code
	if (out ~ /[^[:space:]]/) print out
}
