ir = File.binread(ARGV[0]).gsub("\r\n", "\n")   # normalize CRLF
ir.gsub!(/^\$"[^"]*" = comdat [^\n]+\n/, '')    # remove comdat declarations
ir.gsub!(/, comdat(\([^)]*\))?/, '')             # remove comdat attribute
# Change linkonce_odr to private on global variable lines (@name = linkonce_odr ...)
# but NOT on function definitions (those start with 'define', not '@').
ir.gsub!(/^(@(?:"[^"]*"|[^\s]+) = )linkonce_odr /) { "#{$1}private " }
File.binwrite(ARGV[0], ir)
