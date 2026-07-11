# IRB config for web console sessions (ConsoleRunner points $IRBRC here).
# Everything interactive-terminal is turned off so the transcript scraped from
# the PTY stays clean plain text. Unknown keys are ignored by older irb.
IRB.conf[:USE_PAGER]        = false
IRB.conf[:USE_AUTOCOMPLETE] = false
IRB.conf[:USE_MULTILINE]    = false
IRB.conf[:USE_COLORIZE]     = false
IRB.conf[:PROMPT_MODE]      = :SIMPLE
