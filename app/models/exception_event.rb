# One reported occurrence of an ExceptionGroup.
class ExceptionEvent < ApplicationRecord
  belongs_to :exception_group

  def context_hash
    parsed = JSON.parse(context.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def backtrace_lines
    backtrace.to_s.lines.map(&:chomp)
  end
end
